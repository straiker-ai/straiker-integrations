#!/usr/bin/env bash
# Straiker — Azure AI Foundry scanner onboarding
#
# This is the bash twin of azure-foundry-onboarding-setup-powershell.ps1. The two
# do the same things in the same order and print the same report; keep them in
# step when either changes.
#
# WHAT THIS DOES
#   1. Creates (or reuses) an Entra app registration + service principal for the
#      Straiker scanner, and a client secret.
#   2. Enumerates the estate: subscriptions -> AI Foundry accounts -> projects.
#   3. Assigns every role the scanner needs, at every scope it needs them.
#   4. VERIFIES with the service principal's OWN credentials that each project is
#      actually readable — calling the same API the scanner calls.
#   5. Prints a per-subscription / per-account / per-project report.
#
# WHY VERIFICATION MATTERS
#   A role assignment succeeding is not the same as access working. Azure RBAC
#   takes 30s-5min to propagate, some projects sit behind a virtual network that
#   no role grant can reach, and the data-plane call the scanner makes is not the
#   one a control-plane role implies. So this script assigns first, then polls the
#   data plane until it either works or the deadline passes, and reports each
#   project individually.
#
#   Verification calls GET /agents — the exact call the scanner makes. Checking a
#   different endpoint can report success on an estate the scanner cannot read.
#
# PREREQUISITES
#   * Azure CLI, signed in:  az login   (add --tenant for multi-tenant)
#   * python3 on PATH (used to parse Azure API responses)
#   * Owner or User Access Administrator on each subscription you onboard.
#     Anything less cannot create role assignments.
#
# ROLES ASSIGNED
#   Reader             @ each subscription   ARM discovery: subscriptions,
#                                            Foundry accounts, projects,
#                                            App Insights components
#   Monitoring Reader  @ each subscription   App Insights KQL — required for agent
#                                            conversations
#   Foundry User       @ each subscription   Foundry data plane, inherited
#                      @ each project        Foundry data plane, explicit. Granted
#                                            at both scopes on purpose: the project
#                                            grant takes effect quickly and makes
#                                            verification meaningful, the
#                                            subscription grant is the safety net
#                                            if a project grant fails.
#
# USAGE
#   ./azure-foundry-onboarding-setup-bash.sh
#   ./azure-foundry-onboarding-setup-bash.sh --subscriptions sub1,sub2
#   ./azure-foundry-onboarding-setup-bash.sh --verify-only \
#       --client-id <id> --client-secret <secret> --subscriptions sub1

APP_NAME="straiker-foundry-scanner"
ARM="https://management.azure.com"
ACCOUNTS_API="2023-05-01"
PROJECTS_API="2025-04-01-preview"   # accounts/projects child resource
# Assign by GUID, not name: this role was renamed from "Azure AI User" and the
# name is not consistent across tenants during the rollout.
FOUNDRY_USER_ROLE_ID="53ca6127-db72-4b80-b1b0-d745d6d5456d"

VERIFY_ONLY=0
ARG_CLIENT_ID=""
ARG_CLIENT_SECRET=""
VERIFY_TIMEOUT_MIN=10
SUB_LIST=()

usage() {
  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --subscriptions)   IFS=',' read -r -a SUB_LIST <<< "$2"; shift 2 ;;
    --app-name)        APP_NAME="$2"; shift 2 ;;
    --verify-only)     VERIFY_ONLY=1; shift ;;
    --client-id)       ARG_CLIENT_ID="$2"; shift 2 ;;
    --client-secret)   ARG_CLIENT_SECRET="$2"; shift 2 ;;
    --verify-timeout)  VERIFY_TIMEOUT_MIN="$2"; shift 2 ;;
    -h|--help)         usage ;;
    *) echo "unknown option: $1 (try --help)"; exit 1 ;;
  esac
done

# ── Output helpers ───────────────────────────────────────────────────────────

_head() { echo ""; echo "$1"; printf '%.0s─' $(seq 1 74); echo ""; }
_row()  { printf "  [%-7s] %s\n" "$1" "$2"; [ -n "$3" ] && echo "            $3"; }

# ── HTTP helpers ─────────────────────────────────────────────────────────────

_py() { python3 -c "$1" "${@:2}" 2>/dev/null; }

# ARM GET with nextLink paging (uses YOUR az login). Prints a JSON array of every
# item in "value" across all pages. Exit status 1 means the FIRST call failed and
# nothing was collected.
#
# Every step is defensive about partial results, because the previous version was
# not and it cost us a debugging round: a nextLink page that failed to parse
# overwrote the accumulator with an empty string, so a subscription with accounts
# reported as if it had none. Rule here: once page 1 parses, we always return what
# we have, and a later page that misbehaves just ends the walk.
_arm_list() {
  local url="$1" acc="[]" page merged next pages=0
  while [ -n "$url" ] && [ "$pages" -lt 50 ]; do
    page=$(az rest --method get --url "$url" -o json 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$page" ]; then
      [ "$pages" -eq 0 ] && { echo "[]"; return 1; }
      break
    fi

    merged=$(_py 'import sys,json
a = json.loads(sys.argv[1])
try:
    p = json.loads(sys.argv[2])
except Exception:
    print(json.dumps(a)); raise SystemExit
v = p.get("value")
print(json.dumps(a + (v if isinstance(v, list) else [])))' "$acc" "$page")
    # Keep the previous accumulator if the merge itself produced nothing.
    [ -n "$merged" ] && acc="$merged"

    next=$(_py 'import sys,json
try:
    print(json.loads(sys.argv[1]).get("nextLink") or "")
except Exception:
    print("")' "$page")
    url="$next"
    pages=$((pages + 1))
  done
  echo "$acc"
}

# Client-credentials token for the SP, so every check below sees exactly what the
# Straiker scanner will see rather than what your admin login can see.
#
# Sets _TOKEN and, when that is empty, _TOKEN_ERR with what the token endpoint
# actually said. It sets globals instead of printing the token because a caller
# using $( ) would run this in a subshell and lose the error, which is how an
# earlier version came to abort with no explanation at all.
_get_token() { # $1 = scope
  local resp
  resp=$(curl -s -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
    --data-urlencode "client_id=$APP_ID" \
    --data-urlencode "client_secret=$CLIENT_SECRET" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "scope=$1")

  _TOKEN=$(printf '%s' "$resp" | _py 'import sys,json
try: print(json.load(sys.stdin).get("access_token") or "")
except Exception: print("")')

  _TOKEN_ERR=""
  if [ -z "$_TOKEN" ]; then
    _TOKEN_ERR=$(printf '%s' "$resp" | _py 'import sys,json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print(("non-JSON response from the token endpoint: " + raw[:200]).strip()); raise SystemExit
msg = (str(d.get("error") or "") + " " + str(d.get("error_description") or "")).strip()
print(msg[:300] if msg else "the token endpoint returned no access_token")')
  fi
}

# GET with a bearer token; sets _HTTP_CODE and _HTTP_BODY. Both are needed: the
# status decides retry, the body decides classification.
_http_get() {
  local out
  out=$(curl -s -w $'\n%{http_code}' -H "Authorization: Bearer $2" "$1")
  _HTTP_CODE="${out##*$'\n'}"
  _HTTP_BODY="${out%$'\n'*}"
}

# Turns a data-plane failure into an actionable classification; sets _KIND and
# _REASON. The distinction between a missing role and a network block matters:
# only the first is fixable by this script, and telling a firewalled customer to
# "wait for propagation" sends them down a road that never ends.
_classify() {
  local code="$1" body="$2"
  if echo "$body" | grep -qiE 'virtual network|firewall|public access is disabled|private endpoint'; then
    _KIND="blocked"; _REASON="network rules block access (virtual network / firewall / private endpoint)"
  elif [ "$code" = "403" ]; then
    _KIND="denied";  _REASON="role not effective yet — or not assigned"
  elif [ "$code" = "404" ]; then
    _KIND="denied";  _REASON="project or agents API not found (404)"
  elif [ "$code" = "000" ] || [ -z "$code" ]; then
    _KIND="pending"; _REASON="no response — network or transient error"
  else
    _KIND="pending"; _REASON="HTTP $code"
  fi
}

# Assign a role; sets _ASSIGN_OK (0/1) and _ASSIGN_ERR. ARM writes are throttled,
# and a large estate can make hundreds of them.
_assign_role() { # $1=role (name or GUID)  $2=scope  $3=label  $4=display
  local disp="${4:-$1}" result attempt=1
  _ASSIGN_OK=0; _ASSIGN_ERR=""
  while [ "$attempt" -le 4 ]; do
    result=$(az role assignment create --assignee-object-id "$SP_ID" \
      --assignee-principal-type ServicePrincipal \
      --role "$1" --scope "$2" 2>&1)
    if [ $? -eq 0 ]; then
      _row "OK" "$disp @ $3"; _ASSIGN_OK=1; return 0
    fi
    if echo "$result" | grep -qi "RoleAssignmentExists\|already exists"; then
      _row "EXISTS" "$disp @ $3"; _ASSIGN_OK=1; return 0
    fi
    if echo "$result" | grep -qi "AuthorizationFailed\|does not have authorization"; then
      _row "DENIED" "$disp @ $3" "you need Owner or User Access Administrator at this scope"
      _ASSIGN_ERR="authorization failed"; return 1
    fi
    if echo "$result" | grep -qi "TooManyRequests\|429\|throttl" && [ "$attempt" -lt 4 ]; then
      sleep $((5 * attempt)); attempt=$((attempt + 1)); continue
    fi
    _row "DENIED" "$disp @ $3" "$(echo "$result" | head -1 | cut -c1-160)"
    _ASSIGN_ERR="$(echo "$result" | head -1)"; return 1
  done
  _ASSIGN_ERR="exhausted retries"; return 1
}

# ── Step 0: session ──────────────────────────────────────────────────────────

TENANT_ID=$(az account show --query tenantId -o tsv 2>/dev/null)
if [ -z "$TENANT_ID" ]; then
  echo "ERROR: not signed in. Run: az login"
  exit 1
fi

echo "Straiker — Azure AI Foundry onboarding"
echo "Tenant: $TENANT_ID"

# ── Step 1: choose subscriptions ─────────────────────────────────────────────

if [ ${#SUB_LIST[@]} -eq 0 ]; then
  _head "Subscriptions you can see in this tenant"
  VISIBLE=$(az account list --query "[?tenantId=='$TENANT_ID' && state=='Enabled'].[id,name]" -o tsv 2>/dev/null)
  echo "$VISIBLE" | while IFS=$'\t' read -r i n; do [ -n "$i" ] && echo "    $i  ($n)"; done
  printf "Subscription IDs to onboard (comma-separated, or Enter for ALL of the above): "
  read -r _raw_subs
  if [ -z "$_raw_subs" ]; then
    while IFS=$'\t' read -r i n; do [ -n "$i" ] && SUB_LIST+=("$i"); done <<< "$VISIBLE"
  else
    IFS=',' read -r -a _tmp <<< "$_raw_subs"
    for s in "${_tmp[@]}"; do
      s=$(echo "$s" | tr -d '[:space:]')
      [ -n "$s" ] && SUB_LIST+=("$s")
    done
  fi
fi
if [ ${#SUB_LIST[@]} -eq 0 ]; then
  echo "ERROR: no subscriptions selected."
  exit 1
fi
echo ""
echo "Onboarding ${#SUB_LIST[@]} subscription(s)."

# ── Step 2: app registration, service principal, secret ──────────────────────

if [ "$VERIFY_ONLY" = "1" ]; then
  if [ -z "$ARG_CLIENT_ID" ] || [ -z "$ARG_CLIENT_SECRET" ]; then
    echo "ERROR: --verify-only needs --client-id and --client-secret (no new credential is created)."
    exit 1
  fi
  APP_ID="$ARG_CLIENT_ID"
  CLIENT_SECRET="$ARG_CLIENT_SECRET"
  SP_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null)
  if [ -z "$SP_ID" ]; then
    echo "ERROR: no service principal for client id $APP_ID in tenant $TENANT_ID."
    exit 1
  fi
  _head "Verify only — no roles will be assigned"
  echo "  app id:    $APP_ID"
  echo "  object id: $SP_ID"
else
  _head "Service principal"
  APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv 2>/dev/null)
  if [ -n "$APP_ID" ]; then
    _row "EXISTS" "app registration '$APP_NAME' ($APP_ID)"
    SP_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null)
    if [ -z "$SP_ID" ]; then
      SP_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
      sleep 15
    fi
  else
    APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
    SP_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
    sleep 15   # Entra replication
    _row "OK" "app registration '$APP_NAME' created ($APP_ID)"
  fi
  echo "            object id: $SP_ID  (this is the id that appears in Straiker's errors)"

  CLIENT_SECRET=$(az ad app credential reset --id "$APP_ID" --years 2 --append --query password -o tsv)
  _row "OK" "client secret created (valid 2 years)"
fi

# ── Step 3: enumerate the estate ─────────────────────────────────────────────
# Done with YOUR login, so the inventory is complete even where the SP has no
# access yet. That is the point: report what exists, then separately report what
# the SP can actually read.
#
# Parallel indexed arrays rather than maps, so this works on bash 3.2 (macOS).

_head "Estate"

ACC_SUB=();  ACC_ID=();   ACC_NAME=();  ACC_FOUNDRY=(); ACC_SKIP=(); ACC_ERR=()
PRJ_SUB=();  PRJ_ACC=();  PRJ_NAME=();  PRJ_SCOPE=();   PRJ_STATUS=(); PRJ_REASON=()
SUB_NAME=(); SUB_ERR=()

si=0
for SUB in "${SUB_LIST[@]}"; do
  SUB_NAME[$si]=$(az account show --subscription "$SUB" --query name -o tsv 2>/dev/null)
  SUB_ERR[$si]=""

  # `az cognitiveservices account list` is preferred over a raw ARM call because
  # the CLI walks nextLink itself. This response IS paginated in real tenants —
  # ARM returned a %24skiptoken nextLink on the very first subscription we tested
  # against — and hand-rolled paging is where this script went wrong before.
  ACC_JSON=$(az cognitiveservices account list --subscription "$SUB" -o json 2>/dev/null)
  if [ -z "$ACC_JSON" ]; then
    # Fall back to the raw ARM walk; some tenants/CLI versions refuse the above.
    ACC_JSON=$(_arm_list "$ARM/subscriptions/$SUB/providers/Microsoft.CognitiveServices/accounts?api-version=$ACCOUNTS_API")
    if [ $? -ne 0 ]; then
      SUB_ERR[$si]="cannot list Cognitive Services accounts"
      _row "SKIP" "subscription/$SUB" "${SUB_ERR[$si]}"
      si=$((si + 1))
      continue
    fi
  fi

  # How many accounts ARM returned at all, before any Foundry filtering. Printed
  # because "no Foundry accounts" and "no accounts" and "the response could not be
  # parsed" are three different problems that used to look identical here.
  ACC_TOTAL=$(printf '%s' "$ACC_JSON" | _py 'import sys,json; print(len(json.load(sys.stdin)))')
  ACC_TOTAL=${ACC_TOTAL:-parse-failed}

  if [ "$ACC_TOTAL" = "parse-failed" ]; then
    SUB_ERR[$si]="could not parse the Cognitive Services account list returned by ARM"
    _row "DENIED" "subscription/$SUB" "${SUB_ERR[$si]}"
    si=$((si + 1))
    continue
  fi
  if [ "$ACC_TOTAL" = "0" ]; then
    _row "SKIP" "subscription/$SUB" "no Cognitive Services accounts exist in this subscription"
    si=$((si + 1))
    continue
  fi
  _row "OK" "subscription/$SUB — $ACC_TOTAL Cognitive Services account(s) returned by ARM"

  # A Foundry account exposes a *.services.ai.azure.com endpoint — the rule the
  # Straiker scanner applies. `kind == AIServices` is accepted too, because the
  # CLI's account list does not always carry the endpoints map, and treating a
  # real Foundry account as non-Foundry silently skips granting its projects.
  #
  # str(v) rather than (v or ""): an endpoints map holding a non-string value
  # would otherwise raise and discard the whole list.
  ACCOUNTS=$(printf '%s' "$ACC_JSON" | _py 'import sys,json
try:
    items = json.load(sys.stdin)
except Exception:
    raise SystemExit
for a in items if isinstance(items, list) else []:
    eps  = (a.get("properties") or {}).get("endpoints") or {}
    vals = list(eps.values()) if hasattr(eps, "values") else []
    kind = str(a.get("kind") or "")
    foundry = any(".services.ai.azure.com" in str(v) for v in vals) or kind == "AIServices"
    print("|".join([str(a.get("id","")), str(a.get("name","")), "1" if foundry else "0", kind or "unknown"]))')

  if [ -z "$ACCOUNTS" ]; then
    SUB_ERR[$si]="ARM returned $ACC_TOTAL account(s) but none could be read — report this to Straiker"
    _row "DENIED" "subscription/$SUB" "${SUB_ERR[$si]}"
    si=$((si + 1))
    continue
  fi

  while IFS='|' read -r A_ID A_NAME A_FOUNDRY A_KIND; do
    [ -z "$A_ID" ] && continue
    ai=${#ACC_ID[@]}
    ACC_SUB[$ai]="$SUB"; ACC_ID[$ai]="$A_ID"; ACC_NAME[$ai]="$A_NAME"
    ACC_FOUNDRY[$ai]="$A_FOUNDRY"; ACC_SKIP[$ai]=""; ACC_ERR[$ai]=""

    if [ "$A_FOUNDRY" != "1" ]; then
      ACC_SKIP[$ai]="not an AI Foundry account (kind=$A_KIND, no services.ai.azure.com endpoint)"
      _row "SKIP" "$A_NAME" "${ACC_SKIP[$ai]}"
      continue
    fi

    PROJ_JSON=$(_arm_list "$ARM$A_ID/projects?api-version=$PROJECTS_API")
    if [ $? -ne 0 ]; then
      ACC_ERR[$ai]="cannot list projects"
      _row "SKIP" "$A_NAME" "${ACC_ERR[$ai]}"
      continue
    fi
    # ARM returns child-resource names as "account/project" — keep the leaf only.
    PROJECTS=$(printf '%s' "$PROJ_JSON" | _py 'import sys,json
for p in json.load(sys.stdin): print(p["name"].split("/")[-1])')

    _count=0
    while IFS= read -r P; do
      [ -z "$P" ] && continue
      pi=${#PRJ_NAME[@]}
      PRJ_SUB[$pi]="$SUB"; PRJ_ACC[$pi]="$A_NAME"; PRJ_NAME[$pi]="$P"
      PRJ_SCOPE[$pi]="$A_ID/projects/$P"; PRJ_STATUS[$pi]="unknown"; PRJ_REASON[$pi]=""
      _count=$((_count + 1))
    done <<< "$PROJECTS"
    _row "OK" "$A_NAME — $_count project(s)"
  done <<< "$ACCOUNTS"

  si=$((si + 1))
done

echo ""
echo "Found ${#SUB_LIST[@]} subscription(s), $(printf '%s\n' "${ACC_FOUNDRY[@]}" 2>/dev/null | grep -c '^1$') Foundry account(s), ${#PRJ_NAME[@]} project(s)."
if [ ${#PRJ_NAME[@]} -eq 0 ]; then
  echo "WARNING: no Foundry projects found. Check the subscriptions contain AI Foundry accounts."
fi

# ── Step 4: assign every role, everywhere, in one pass ───────────────────────
# Assign first and verify later, deliberately. Verifying each project right after
# assigning it would pay the propagation wait once per project; assigning
# everything first lets all of them propagate concurrently.

if [ "$VERIFY_ONLY" != "1" ]; then
  _head "Assigning roles"
  for SUB in "${SUB_LIST[@]}"; do
    _assign_role "Reader"                 "/subscriptions/$SUB" "subscription/$SUB" "Reader" || \
      echo "            Reader is required for discovery — later checks on this subscription will fail."
    _assign_role "Monitoring Reader"      "/subscriptions/$SUB" "subscription/$SUB" "Monitoring Reader"
    _assign_role "$FOUNDRY_USER_ROLE_ID"  "/subscriptions/$SUB" "subscription/$SUB" "Foundry User"
  done

  i=0
  while [ $i -lt ${#PRJ_NAME[@]} ]; do
    if _assign_role "$FOUNDRY_USER_ROLE_ID" "${PRJ_SCOPE[$i]}" "${PRJ_ACC[$i]}/${PRJ_NAME[$i]}" "Foundry User"; then
      PRJ_STATUS[$i]="assigned"
    else
      PRJ_STATUS[$i]="assign_failed"; PRJ_REASON[$i]="$_ASSIGN_ERR"
    fi
    i=$((i + 1))
  done
fi

# ── Step 5: verify as the service principal, in waves ────────────────────────
# Each wave retries only what has not succeeded, so total time is the longest
# propagation rather than the sum of them. Network-blocked projects leave the
# retry set immediately — no role grant will ever fix those.

_head "Verifying with the service principal"

ARM_TOKEN=""
for _try in 1 2 3 4 5 6; do
  _get_token "$ARM/.default"
  ARM_TOKEN="$_TOKEN"
  [ -n "$ARM_TOKEN" ] && break
  echo "  waiting for the credential to become usable... (${_TOKEN_ERR:-no detail})"
  sleep 10
done
if [ -z "$ARM_TOKEN" ]; then
  _row "DENIED" "ARM token" "${_TOKEN_ERR:-unknown error}"
  echo "  Check the client id and secret. The roles above were assigned and remain in place."
  exit 1
fi

# A missing Foundry token stops per-project verification but must not abort the
# run: the role assignments above already happened, and the report below is what
# the customer sends us. Reporting the reason beats exiting silently.
_get_token "https://ai.azure.com/.default"
FOUNDRY_TOKEN="$_TOKEN"
if [ -z "$FOUNDRY_TOKEN" ]; then
  _row "DENIED" "Foundry data-plane token" "${_TOKEN_ERR:-unknown error}"
  echo "  Per-project verification cannot run without this token, so every project"
  echo "  below is reported as unverified. Role assignments are unaffected."
fi

# Subscription-level reads, as the SP.
si=0
for SUB in "${SUB_LIST[@]}"; do
  _http_get "$ARM/subscriptions/$SUB/providers/Microsoft.CognitiveServices/accounts?api-version=$ACCOUNTS_API" "$ARM_TOKEN"
  if [ "$_HTTP_CODE" = "200" ]; then
    _n=$(printf '%s' "$_HTTP_BODY" | _py 'import sys,json; print(len(json.load(sys.stdin).get("value",[])))')
    # A 200 with zero accounts is normal right after onboarding: ARM returns an
    # empty list rather than an error while a fresh Reader grant propagates. Said
    # explicitly, because "[OK] ... (0)" reads like a contradiction next to
    # projects that verified fine seconds later.
    if [ "${_n:-0}" = "0" ]; then
      _row "PENDING" "subscription/$SUB — SP sees 0 accounts" "Reader is still propagating; per-project results below are authoritative"
    else
      _row "OK" "subscription/$SUB — SP can list accounts (${_n})"
    fi
  else
    SUB_ERR[$si]="SP cannot list accounts (HTTP $_HTTP_CODE)"
    _row "DENIED" "subscription/$SUB — SP cannot list accounts" "Reader missing or not yet propagated"
  fi
  si=$((si + 1))
done

DEADLINE=$(( $(date +%s) + VERIFY_TIMEOUT_MIN * 60 ))
WAVE=0
while [ -n "$FOUNDRY_TOKEN" ]; do
  WAVE=$((WAVE + 1))
  REMAINING=0
  i=0
  while [ $i -lt ${#PRJ_NAME[@]} ]; do
    case "${PRJ_STATUS[$i]}" in
      ok|blocked|denied_final) i=$((i + 1)); continue ;;
    esac

    # GET /agents is what the Straiker scanner calls. Verifying anything else can
    # report success on an estate the scanner cannot read.
    _http_get "https://${PRJ_ACC[$i]}.services.ai.azure.com/api/projects/${PRJ_NAME[$i]}/agents?api-version=v1" "$FOUNDRY_TOKEN"
    if [ "$_HTTP_CODE" = "200" ]; then
      PRJ_STATUS[$i]="ok"; PRJ_REASON[$i]=""
      _row "OK" "${PRJ_ACC[$i]}/${PRJ_NAME[$i]} — agents readable"
    else
      _classify "$_HTTP_CODE" "$_HTTP_BODY"
      PRJ_REASON[$i]="$_REASON"
      if [ "$_KIND" = "blocked" ]; then
        PRJ_STATUS[$i]="blocked"
        _row "BLOCKED" "${PRJ_ACC[$i]}/${PRJ_NAME[$i]}" "$_REASON"
      elif [ "$(date +%s)" -lt "$DEADLINE" ]; then
        PRJ_STATUS[$i]="retrying"
        REMAINING=$((REMAINING + 1))
      else
        PRJ_STATUS[$i]="denied_final"
        _row "DENIED" "${PRJ_ACC[$i]}/${PRJ_NAME[$i]}" "$_REASON"
      fi
    fi
    i=$((i + 1))
  done

  [ "$REMAINING" -eq 0 ] && break
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    i=0
    while [ $i -lt ${#PRJ_NAME[@]} ]; do
      if [ "${PRJ_STATUS[$i]}" = "retrying" ]; then
        PRJ_STATUS[$i]="pending"
        PRJ_REASON[$i]="not readable within the verification window; Straiker re-checks every scan"
        _row "PENDING" "${PRJ_ACC[$i]}/${PRJ_NAME[$i]}" "${PRJ_REASON[$i]}"
      fi
      i=$((i + 1))
    done
    break
  fi
  echo "  wave $WAVE — $REMAINING project(s) not readable yet, retrying in 30s (role propagation takes 30s-5min)..."
  sleep 30
done

# Normalise the terminal status names used by the report below.
i=0
while [ $i -lt ${#PRJ_NAME[@]} ]; do
  [ "${PRJ_STATUS[$i]}" = "denied_final" ] && PRJ_STATUS[$i]="denied"
  case "${PRJ_STATUS[$i]}" in
    assigned|assign_failed|unknown|retrying)
      PRJ_STATUS[$i]="pending"
      [ -z "${PRJ_REASON[$i]}" ] && PRJ_REASON[$i]="not verified"
      ;;
  esac
  i=$((i + 1))
done

# App Insights, best effort: conversations need Monitoring Reader plus a linked
# component. Reported, never fatal.
_get_token "https://api.applicationinsights.io/.default"
AI_TOKEN="$_TOKEN"
AI_TOKEN_ERR="$_TOKEN_ERR"
AI_APP_ID=""
for SUB in "${SUB_LIST[@]}"; do
  [ -n "$AI_APP_ID" ] && break
  _http_get "$ARM/subscriptions/$SUB/providers/microsoft.insights/components?api-version=2020-02-02" "$ARM_TOKEN"
  [ "$_HTTP_CODE" = "200" ] && AI_APP_ID=$(printf '%s' "$_HTTP_BODY" | _py 'import sys,json; v=json.load(sys.stdin).get("value",[]); print(v[0]["properties"]["AppId"] if v else "")')
done
if [ -z "$AI_APP_ID" ]; then
  _row "SKIP" "App Insights" "no component found in scope — agent conversations will not be collected"
elif [ -n "$AI_TOKEN" ]; then
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "https://api.applicationinsights.io/v1/apps/$AI_APP_ID/query" \
    -H "Authorization: Bearer $AI_TOKEN" -H "Content-Type: application/json" \
    -d '{"query":"dependencies | limit 1","timespan":"PT1H"}')
  if [ "$HTTP" = "200" ]; then
    _row "OK" "App Insights KQL query (Monitoring Reader)"
  else
    _row "DENIED" "App Insights KQL query" "Monitoring Reader missing or not yet propagated"
  fi
else
  _row "DENIED" "App Insights token" "${AI_TOKEN_ERR:-could not obtain an App Insights token}"
fi

# ── Step 6: report ───────────────────────────────────────────────────────────
# Rendered as a tree rather than a table: a table truncates the reason, and the
# reason is the only part a customer can act on. Everything the script saw is
# listed here — including accounts it skipped — so this console output is the
# complete record, copy-pasteable into a ticket.

_head "Result — every subscription, account and project"
si=0
for SUB in "${SUB_LIST[@]}"; do
  _sn="${SUB_NAME[$si]}"
  echo ""
  if [ -n "$_sn" ]; then echo "  subscription $SUB ($_sn)"; else echo "  subscription $SUB"; fi
  [ -n "${SUB_ERR[$si]}" ] && echo "      ! ${SUB_ERR[$si]}"

  _any_acc=0
  ai=0
  while [ $ai -lt ${#ACC_ID[@]} ]; do
    if [ "${ACC_SUB[$ai]}" = "$SUB" ]; then
      _any_acc=1
      if [ "${ACC_FOUNDRY[$ai]}" != "1" ]; then
        echo "      account ${ACC_NAME[$ai]} — skipped: ${ACC_SKIP[$ai]}"
      else
        echo "      account ${ACC_NAME[$ai]}"
        [ -n "${ACC_ERR[$ai]}" ] && echo "          ! ${ACC_ERR[$ai]}"
        _any_proj=0
        pi=0
        while [ $pi -lt ${#PRJ_NAME[@]} ]; do
          # Matched on the account's ARM id via the project scope, not on its
          # name: two accounts in different resource groups can share a name, and
          # name matching then printed one account's projects under both.
          if [ "${PRJ_SUB[$pi]}" = "$SUB" ] && [ "${PRJ_SCOPE[$pi]}" = "${ACC_ID[$ai]}/projects/${PRJ_NAME[$pi]}" ]; then
            _any_proj=1
            _tag=$(echo "${PRJ_STATUS[$pi]}" | tr '[:lower:]' '[:upper:]')
            if [ -n "${PRJ_REASON[$pi]}" ]; then
              printf "          [%-7s] %s — %s\n" "$_tag" "${PRJ_NAME[$pi]}" "${PRJ_REASON[$pi]}"
            else
              printf "          [%-7s] %s\n" "$_tag" "${PRJ_NAME[$pi]}"
            fi
          fi
          pi=$((pi + 1))
        done
        [ "$_any_proj" = "0" ] && echo "          (no projects)"
      fi
    fi
    ai=$((ai + 1))
  done
  [ "$_any_acc" = "0" ] && echo "      (no Cognitive Services accounts)"

  si=$((si + 1))
done

OK_COUNT=0; PENDING_COUNT=0; DENIED_COUNT=0; BLOCKED_COUNT=0
i=0
while [ $i -lt ${#PRJ_NAME[@]} ]; do
  case "${PRJ_STATUS[$i]}" in
    ok)      OK_COUNT=$((OK_COUNT + 1)) ;;
    pending) PENDING_COUNT=$((PENDING_COUNT + 1)) ;;
    blocked) BLOCKED_COUNT=$((BLOCKED_COUNT + 1)) ;;
    *)       DENIED_COUNT=$((DENIED_COUNT + 1)) ;;
  esac
  i=$((i + 1))
done

_head "Summary"
echo "  readable now      $OK_COUNT"
echo "  pending           $PENDING_COUNT   (should resolve on its own; Straiker re-checks every scan)"
echo "  denied            $DENIED_COUNT"
echo "  network blocked   $BLOCKED_COUNT"

if [ "$BLOCKED_COUNT" -gt 0 ]; then
  echo ""
  echo "  Network-blocked projects need Straiker's access allowlisted on the resource,"
  echo "  or a private endpoint. A role assignment cannot reach them."
fi
if [ "$DENIED_COUNT" -gt 0 ]; then
  echo ""
  echo "  Denied projects: confirm you hold Owner or User Access Administrator on the"
  echo "  subscription, then re-run this script."
fi

echo ""
echo "  Please copy this output and send it to Straiker — it is the record of"
echo "  what was found and what is reachable."

if [ "$VERIFY_ONLY" != "1" ]; then
  _head "Paste these values into Straiker"
  echo "  Tenant ID:        $TENANT_ID"
  echo "  Subscription IDs: $(IFS=,; echo "${SUB_LIST[*]}")"
  echo "  Client ID:        $APP_ID"
  echo "  Client Secret:    $CLIENT_SECRET"
  echo ""
  echo "  The secret is shown once. Copy it now."
fi

# Denied is actionable and should fail automation; pending is expected and should not.
[ "$DENIED_COUNT" -gt 0 ] && exit 1
exit 0
