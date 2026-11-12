#!/usr/bin/env bash
# Straiker: connect Databricks workspaces (Discover, and optionally Ascend on Genie spaces).
#
# Creates or reuses the Straiker service principals in the workspaces you name, grants them
# what Straiker needs, mints OAuth secrets pinned to narrow scopes, and prints the values to
# paste into the Straiker console. Nothing is sent to Straiker and nothing is written to disk.
#
# Docs: https://github.com/straiker-ai/straiker-integrations/tree/main/platforms/databricks
set -euo pipefail

readonly DISCOVER_SCOPES='["genie:read","access-management:read","unity-catalog:read"]'
readonly ASCEND_SCOPES='["genie"]'
readonly HOST_RE='^https://[a-z0-9][a-z0-9.-]*\.(cloud\.databricks\.com|azuredatabricks\.net|gcp\.databricks\.com)$'

usage() {
  cat <<'EOF'
Usage: setup.sh --workspaces URL[,URL...] (--profile NAME | --profile-map URL=NAME[,...])
                [--ascend-spaces ID[,ID...]] [--discover-name NAME] [--ascend-name NAME]
                [--dry-run] [--help]

Grants Straiker access to Databricks workspaces. Run it as a workspace admin who is already
logged in with the Databricks CLI (databricks auth login --host <workspace URL>).

  --workspaces URL[,...]       Workspace URLs (https://<name>.cloud.databricks.com,
                               *.azuredatabricks.net or *.gcp.databricks.com). Required.
  --profile NAME               Databricks CLI profile used for every workspace.
  --profile-map URL=NAME,...   CLI profile per workspace (one profile holds one host).
  --ascend-spaces ID[,...]     Genie space IDs Ascend may test. Creates the Ascend principal.
  --discover-name NAME         Discover service principal name (default: straiker-discover).
  --ascend-name NAME           Ascend service principal name (default: straiker-ascend).
  --dry-run                    Print every change with placeholders; change nothing. Read-only
                               lookups still run so the plan shows real IDs.
  -h, --help                   Show this help.

What it does:
  Discover: one service principal, added to each workspace's "admins" group so it can see every
  Genie space; its OAuth secret is pinned to genie:read, access-management:read and
  unity-catalog:read, so it cannot run SQL, prompt Genie, read secrets or manage users.
  Ascend (only with --ascend-spaces): a second service principal with a secret pinned to genie,
  CAN_READ on each space, CAN_USE on each space's SQL warehouse and USE CATALOG / USE SCHEMA /
  SELECT on each table in the space.

Output: the values to paste into Straiker, printed once to stdout. Re-running creates a new
secret and prints the command to delete older ones.
EOF
}

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

WORKSPACES_ARG=""
ASCEND_SPACES_ARG=""
DISCOVER_NAME="straiker-discover"
ASCEND_NAME="straiker-ascend"
PROFILE=""
PROFILE_MAP=""
DRY_RUN=0

need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value (try --help)"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspaces) need_value "$@"; WORKSPACES_ARG="$2"; shift 2 ;;
    --workspaces=*) WORKSPACES_ARG="${1#*=}"; shift ;;
    --ascend-spaces) need_value "$@"; ASCEND_SPACES_ARG="$2"; shift 2 ;;
    --ascend-spaces=*) ASCEND_SPACES_ARG="${1#*=}"; shift ;;
    --discover-name) need_value "$@"; DISCOVER_NAME="$2"; shift 2 ;;
    --discover-name=*) DISCOVER_NAME="${1#*=}"; shift ;;
    --ascend-name) need_value "$@"; ASCEND_NAME="$2"; shift 2 ;;
    --ascend-name=*) ASCEND_NAME="${1#*=}"; shift ;;
    --profile) need_value "$@"; PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --profile-map) need_value "$@"; PROFILE_MAP="$2"; shift 2 ;;
    --profile-map=*) PROFILE_MAP="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ── Input validation ─────────────────────────────────────────────────────────

norm_host() {
  local h
  h="$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  while [[ "$h" == */ ]]; do h="${h%/}"; done
  printf '%s' "$h"
}

count_lines() { printf '%s\n' "$1" | grep -c . || true; }

split_csv() { printf '%s\n' "$1" | tr ',' '\n' | tr -d '[:blank:]' | sed '/^$/d'; }

[[ -n "$WORKSPACES_ARG" ]] || die "--workspaces is required (try --help)"
[[ -z "$PROFILE" || -z "$PROFILE_MAP" ]] || die "use --profile or --profile-map, not both"
[[ -n "$PROFILE" || -n "$PROFILE_MAP" ]] || die "--profile or --profile-map is required (try --help)"
for n in "$DISCOVER_NAME" "$ASCEND_NAME"; do
  [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "invalid service principal name: $n"
done
[[ "$DISCOVER_NAME" != "$ASCEND_NAME" ]] || die "--discover-name and --ascend-name must differ"

WS=()
while IFS= read -r raw; do
  h="$(norm_host "$raw")"
  [[ "$h" =~ $HOST_RE ]] || die "not a Databricks workspace URL: $raw (expected https://<name>.cloud.databricks.com, .azuredatabricks.net or .gcp.databricks.com)"
  for seen in ${WS[@]+"${WS[@]}"}; do [[ "$seen" != "$h" ]] || die "workspace listed twice: $h"; done
  WS+=("$h")
done < <(split_csv "$WORKSPACES_ARG")
[[ ${#WS[@]} -gt 0 ]] || die "--workspaces contained no URL"

cloud_of() {
  case "$1" in
    *.cloud.databricks.com) printf 'AWS' ;;
    *.azuredatabricks.net) printf 'Azure' ;;
    *.gcp.databricks.com) printf 'Google Cloud' ;;
  esac
}
CLOUD="$(cloud_of "${WS[0]}")"
for h in "${WS[@]}"; do
  [[ "$(cloud_of "$h")" == "$CLOUD" ]] || die "all workspaces must be on one cloud (a connection to another cloud is a separate Straiker integration)"
done

SPACES=()
if [[ -n "$ASCEND_SPACES_ARG" ]]; then
  while IFS= read -r s; do
    [[ "$s" =~ ^[A-Za-z0-9]+$ ]] || die "invalid Genie space ID: $s"
    SPACES+=("$s")
  done < <(split_csv "$ASCEND_SPACES_ARG")
  [[ ${#SPACES[@]} -gt 0 ]] || die "--ascend-spaces contained no ID"
fi

MAP_HOSTS=()
MAP_PROFILES=()
if [[ -n "$PROFILE_MAP" ]]; then
  while IFS= read -r pair; do
    [[ "$pair" == *=* ]] || die "--profile-map entries look like https://host=profile, got: $pair"
    MAP_HOSTS+=("$(norm_host "${pair%%=*}")")
    MAP_PROFILES+=("${pair#*=}")
  done < <(split_csv "$PROFILE_MAP")
fi

profile_for() {
  local i
  if [[ -n "$PROFILE" ]]; then printf '%s' "$PROFILE"; return 0; fi
  for i in "${!MAP_HOSTS[@]}"; do
    if [[ "${MAP_HOSTS[$i]}" == "$1" ]]; then printf '%s' "${MAP_PROFILES[$i]}"; return 0; fi
  done
  return 1
}

for h in "${WS[@]}"; do
  profile_for "$h" >/dev/null || die "--profile-map has no profile for $h"
done

command -v databricks >/dev/null 2>&1 || die "the Databricks CLI is required (https://docs.databricks.com/dev-tools/cli/install.html)"
command -v jq >/dev/null 2>&1 || die "jq is required (https://jqlang.org/download/)"

# A CLI profile holds one host, so a profile pointing elsewhere would act on the wrong workspace.
if profiles_json="$(databricks auth profiles --skip-validate -o json 2>/dev/null)"; then
  for h in "${WS[@]}"; do
    p="$(profile_for "$h")"
    ph="$(printf '%s' "$profiles_json" | jq -r --arg p "$p" '.profiles[]? | select(.name == $p) | .host' | head -n 1)"
    [[ -n "$ph" ]] || die "no Databricks CLI profile named '$p'. Run: databricks auth login --host $h --profile $p"
    [[ "$(norm_host "$ph")" == "$h" ]] || die "profile '$p' is for $(norm_host "$ph"), not $h. Use --profile-map to give each workspace its own profile."
  done
else
  log "warning: could not read Databricks CLI profiles; skipping the profile/host check"
fi

# ── Command helpers ──────────────────────────────────────────────────────────

quote_args() {
  local a out=""
  for a in "$@"; do
    if [[ "$a" == *"'"* ]]; then
      a="$(printf '%q' "$a")"
    elif [[ -z "$a" || "$a" =~ [^A-Za-z0-9_./:=@%+,-] ]]; then
      a="'$a'"
    fi
    out="${out:+$out }$a"
  done
  printf '%s' "$out"
}

# Read-only call; runs in dry-run too so the plan can show real IDs.
dbx_read() {
  local host="$1"; shift
  databricks "$@" --profile "$(profile_for "$host")"
}

# Mutating call: printed under --dry-run, otherwise run with its JSON output on stdout. The plan
# goes to fd 3 so a caller's >/dev/null cannot hide a step from the reviewer.
exec 3>&1
PLAN_STEP=0
dbx_write() {
  local host="$1"; shift
  local p
  p="$(profile_for "$host")"
  if [[ "$DRY_RUN" == 1 ]]; then
    PLAN_STEP=$((PLAN_STEP + 1))
    printf '  %2d. databricks %s --profile %s\n' "$PLAN_STEP" "$(quote_args "$@")" "$(quote_args "$p")" >&3
    return 0
  fi
  databricks "$@" --profile "$p"
}

FAILURES=()
fail_soft() { FAILURES+=("$1"); log "  FAILED: $1"; }

section() {
  if [[ "$DRY_RUN" == 1 ]]; then printf '\n%s\n' "$1" >&3; else log ""; log "$1"; fi
}
note() {
  if [[ "$DRY_RUN" == 1 ]]; then printf '      %s\n' "$*" >&3; else log "  $*"; fi
}

# ── Service principals ───────────────────────────────────────────────────────

# Prints "<id>\t<applicationId>" for each principal with this display name.
sp_by_name() {
  local host="$1" name="$2" out
  out="$(dbx_read "$host" service-principals list -o json)" || return 1
  printf '%s' "$out" | jq -r --arg n "$name" '.[]? | select(.displayName == $n) | [.id, .applicationId] | @tsv'
}

sp_id_by_app() {
  local host="$1" app="$2" out
  out="$(dbx_read "$host" service-principals list -o json)" || return 1
  printf '%s' "$out" | jq -r --arg a "$app" '[.[]? | select(.applicationId == $a) | .id][0] // empty'
}

# ensure_sp NAME IDX... makes the principal present in the given workspaces, reusing one found by
# name in any listed workspace. Sets SP_APP, SP_IDS[idx] (workspace-local IDs), SP_EXISTED=1 on reuse.
SP_APP=""
SP_IDS=()
SP_EXISTED=0
ensure_sp() {
  local name="$1"; shift
  local idx host matches count id app found_app="" found_in=""
  SP_APP=""; SP_IDS=(); SP_EXISTED=0

  for idx in "${!WS[@]}"; do
    host="${WS[$idx]}"
    if ! matches="$(sp_by_name "$host" "$name")"; then
      [[ "$DRY_RUN" == 1 ]] || die "could not list service principals in $host. Are you a workspace admin, logged in with: databricks auth login --host $host --profile $(profile_for "$host")?"
      log "warning: could not list service principals in $host; the plan shows placeholders"
      continue
    fi
    count="$(count_lines "$matches")"
    [[ "$count" -le 1 ]] || die "$count service principals are named '$name' in $host; remove the extras or choose another name"
    [[ "$count" -eq 1 ]] || continue
    app="$(printf '%s' "$matches" | cut -f2)"
    if [[ -n "$found_app" && "$found_app" != "$app" ]]; then
      die "'$name' is a different service principal in $found_in and $host; choose another name"
    fi
    found_app="$app"; found_in="$host"
  done

  if [[ -n "$found_app" ]]; then
    SP_APP="$found_app"; SP_EXISTED=1
    note "reusing service principal '$name' (application ID $SP_APP)"
  fi

  for idx in "$@"; do
    host="${WS[$idx]}"
    id=""
    if [[ -n "$SP_APP" ]]; then
      id="$(sp_id_by_app "$host" "$SP_APP" 2>/dev/null || true)"
    fi
    if [[ -n "$id" ]]; then
      note "$host: '$name' present (ID $id)"
      SP_IDS[idx]="$id"
      continue
    fi
    if [[ -z "$SP_APP" ]]; then
      local out
      if [[ "$DRY_RUN" == 1 ]]; then
        dbx_write "$host" service-principals create --display-name "$name" -o json
        SP_APP="<$name application ID>"
        SP_IDS[idx]="<$name ID in $host>"
        continue
      fi
      out="$(dbx_write "$host" service-principals create --display-name "$name" -o json)" \
        || die "could not create service principal '$name' in $host"
      SP_APP="$(printf '%s' "$out" | jq -r '.applicationId // empty')"
      id="$(printf '%s' "$out" | jq -r '.id // empty')"
      [[ -n "$SP_APP" && -n "$id" ]] || die "unexpected response creating '$name' in $host"
      log "  $host: created '$name' (ID $id, application ID $SP_APP)"
      SP_IDS[idx]="$id"
    else
      # Adds the same principal to another workspace by application ID.
      # NOT YET VERIFIED LIVE: multi-workspace assignment via the workspace SCIM API.
      local out
      if [[ "$DRY_RUN" == 1 ]]; then
        dbx_write "$host" service-principals create --application-id "$SP_APP" --display-name "$name" -o json
        note "(adds the same principal to this workspace; not yet verified live)"
        SP_IDS[idx]="<$name ID in $host>"
        continue
      fi
      out="$(dbx_write "$host" service-principals create --application-id "$SP_APP" --display-name "$name" -o json)" \
        || die "could not add '$name' ($SP_APP) to $host. Add it in the account console (Workspaces > Permissions), then re-run."
      id="$(printf '%s' "$out" | jq -r '.id // empty')"
      [[ -n "$id" ]] || die "unexpected response adding '$name' to $host"
      log "  $host: added '$name' (ID $id)"
      SP_IDS[idx]="$id"
    fi
  done
}

# ── Secrets ──────────────────────────────────────────────────────────────────

# mint_secret NAME HOST ID SCOPES sets SECRET_VALUE. The secret stays in memory: JSON goes
# through pipes (not here-strings, which older bash writes to a temp file).
SECRET_VALUE=""
mint_secret() {
  local name="$1" host="$2" id="$3" scopes="$4" old_ids="" out new_id old
  SECRET_VALUE=""
  if [[ "$DRY_RUN" == 1 ]]; then
    dbx_write "$host" service-principal-secrets-proxy create "$id" -o json --json "{\"scopes\":$scopes}"
    note "pinned to $scopes; existing secrets are left in place and listed for deletion"
    return 0
  fi
  if out="$(dbx_read "$host" service-principal-secrets-proxy list "$id" -o json 2>/dev/null)"; then
    old_ids="$(printf '%s' "$out" | jq -r '(if type == "array" then . else (.secrets // []) end)[]? | .id // empty')"
  fi
  out="$(dbx_write "$host" service-principal-secrets-proxy create "$id" -o json --json "{\"scopes\":$scopes}")" \
    || die "could not create a secret for '$name' in $host"
  SECRET_VALUE="$(printf '%s' "$out" | jq -r '.secret // empty')"
  new_id="$(printf '%s' "$out" | jq -r '.id // empty')"
  out=""
  [[ -n "$SECRET_VALUE" ]] || die "the secret response for '$name' had no secret"
  log "  created a secret for '$name' pinned to $scopes"
  if [[ -n "$old_ids" ]]; then
    log "  '$name' has older secrets. Once Straiker uses the new one, delete them:"
    while IFS= read -r old; do
      [[ -n "$old" && "$old" != "$new_id" ]] || continue
      log "    databricks service-principal-secrets-proxy delete $id $old --profile $(quote_args "$(profile_for "$host")")"
    done <<<"$old_ids"
  fi
}

# ── Plan header ──────────────────────────────────────────────────────────────

ALL_IDX=()
for i in "${!WS[@]}"; do ALL_IDX+=("$i"); done

if [[ "$DRY_RUN" == 1 ]]; then
  printf 'DRY RUN: nothing will be changed. Commands that would run, in order:\n'
  printf 'Workspaces (%s): %s\n' "$CLOUD" "${WS[*]}"
fi
if [[ "$DRY_RUN" != 1 && ! -t 1 ]]; then
  log "warning: stdout is not a terminal; the secrets printed at the end will go wherever it points"
fi

# ── Discover ─────────────────────────────────────────────────────────────────

section "Discover service principal '$DISCOVER_NAME'"
ensure_sp "$DISCOVER_NAME" "${ALL_IDX[@]}"
DISCOVER_APP="$SP_APP"
DISCOVER_EXISTED="$SP_EXISTED"
DISCOVER_IDS=()
for i in "${ALL_IDX[@]}"; do DISCOVER_IDS[i]="${SP_IDS[$i]:-<$DISCOVER_NAME ID in ${WS[$i]}>}"; done

section "Workspace admin membership (so Discover sees every Genie space)"
note "Genie shows a space's tables and permissions only to its editors, managers or a workspace admin;"
note "the pinned secret is what keeps this principal read-only."
# NOT YET VERIFIED LIVE: adding the principal to "admins" through the SCIM PATCH below. The
# console's verified path is Settings > Identity and access > Groups > admins > Add members.
for i in "${ALL_IDX[@]}"; do
  host="${WS[$i]}"
  sp_id="${DISCOVER_IDS[$i]}"
  admins_id=""
  member="no"
  if groups_json="$(dbx_read "$host" groups list -o json 2>/dev/null)"; then
    admins_id="$(printf '%s' "$groups_json" | jq -r '[.[]? | select(.displayName == "admins") | .id][0] // empty')"
    if [[ -n "$admins_id" ]] && printf '%s' "$groups_json" \
      | jq -e --arg s "$sp_id" '.[]? | select(.displayName == "admins") | .members[]? | select(.value == $s)' >/dev/null; then
      member="yes"
    fi
  fi
  if [[ -z "$admins_id" ]]; then
    [[ "$DRY_RUN" == 1 ]] || { fail_soft "$host: could not find the admins group; add '$DISCOVER_NAME' to admins in the workspace settings"; continue; }
    admins_id="<admins group ID in $host>"
  fi
  if [[ "$member" == "yes" ]]; then
    note "$host: '$DISCOVER_NAME' is already in admins"
    continue
  fi
  body="{\"schemas\":[\"urn:ietf:params:scim:api:messages:2.0:PatchOp\"],\"Operations\":[{\"op\":\"add\",\"path\":\"members\",\"value\":[{\"value\":\"$sp_id\"}]}]}"
  if dbx_write "$host" groups patch "$admins_id" --json "$body" >/dev/null; then
    [[ "$DRY_RUN" == 1 ]] || log "  $host: added '$DISCOVER_NAME' to admins"
  else
    fail_soft "$host: could not add '$DISCOVER_NAME' to admins; add it in Settings > Identity and access > Groups > admins"
  fi
done

# ── Ascend ───────────────────────────────────────────────────────────────────

ASCEND_APP=""
ASCEND_HOST_IDX=""
ASCEND_ID=""
if [[ ${#SPACES[@]} -gt 0 ]]; then
  section "Genie spaces for Ascend"
  SPACE_IDX=()
  SPACE_WH=()
  SPACE_TABLES=()
  for s in "${!SPACES[@]}"; do
    space="${SPACES[$s]}"
    SPACE_IDX[s]=""
    for i in "${ALL_IDX[@]}"; do
      if sj="$(dbx_read "${WS[$i]}" api get "/api/2.0/genie/spaces/$space?include_serialized_space=true" 2>/dev/null)"; then
        SPACE_IDX[s]="$i"
        SPACE_WH[s]="$(printf '%s' "$sj" | jq -r '.warehouse_id // empty')"
        SPACE_TABLES[s]="$(printf '%s' "$sj" | jq -r '(.serialized_space // "{}") | fromjson | .data_sources.tables[]?.identifier // empty' 2>/dev/null || true)"
        break
      fi
    done
    if [[ -z "${SPACE_IDX[$s]}" ]]; then
      [[ "$DRY_RUN" == 1 ]] || die "Genie space $space was not found in any listed workspace (or you cannot edit it)"
      log "warning: Genie space $space not found; the plan uses placeholders"
      SPACE_IDX[s]="0"
      SPACE_WH[s]="<warehouse ID of $space>"
      SPACE_TABLES[s]="<catalog>.<schema>.<table>"
    fi
    n_tables="$(count_lines "${SPACE_TABLES[$s]}")"
    note "space $space in ${WS[${SPACE_IDX[$s]}]}: warehouse ${SPACE_WH[$s]:-<none>}, $n_tables table(s)"
  done

  # One Ascend principal; it only needs to be in the workspaces that host the spaces.
  ASCEND_IDX=()
  for s in "${!SPACES[@]}"; do
    i="${SPACE_IDX[$s]}"
    dup=0
    for j in ${ASCEND_IDX[@]+"${ASCEND_IDX[@]}"}; do [[ "$j" != "$i" ]] || dup=1; done
    [[ "$dup" == 1 ]] || ASCEND_IDX+=("$i")
  done

  section "Ascend service principal '$ASCEND_NAME'"
  note "Genie answers with the caller's own data permissions: grant it what a typical user of the agent has."
  ensure_sp "$ASCEND_NAME" "${ASCEND_IDX[@]}"
  ASCEND_APP="$SP_APP"
  ASCEND_EXISTED="$SP_EXISTED"
  ASCEND_HOST_IDX="${ASCEND_IDX[0]}"
  ASCEND_ID="${SP_IDS[$ASCEND_HOST_IDX]:-<$ASCEND_NAME ID in ${WS[$ASCEND_HOST_IDX]}>}"

  section "Ascend access per space"
  note "Genie fails every question in a space if the caller cannot read any one of its tables,"
  note "so the principal gets CAN_USE on the warehouse and read on every table in the space."
  DONE_KEYS=""
  once() {
    case "$DONE_KEYS" in *"|$1|"*) return 1 ;; esac
    DONE_KEYS="$DONE_KEYS|$1|"
  }
  for s in "${!SPACES[@]}"; do
    space="${SPACES[$s]}"
    host="${WS[${SPACE_IDX[$s]}]}"
    acl="{\"access_control_list\":[{\"service_principal_name\":\"$ASCEND_APP\",\"permission_level\":\"CAN_READ\"}]}"
    dbx_write "$host" api patch "/api/2.0/permissions/genie/$space" --json "$acl" >/dev/null \
      || fail_soft "$host: CAN_READ on Genie space $space"

    wh="${SPACE_WH[$s]}"
    if [[ -z "$wh" ]]; then
      fail_soft "$host: Genie space $space has no warehouse_id; grant CAN_USE on its SQL warehouse by hand"
    elif once "wh|$host|$wh"; then
      acl="{\"access_control_list\":[{\"service_principal_name\":\"$ASCEND_APP\",\"permission_level\":\"CAN_USE\"}]}"
      dbx_write "$host" api patch "/api/2.0/permissions/warehouses/$wh" --json "$acl" >/dev/null \
        || fail_soft "$host: CAN_USE on SQL warehouse $wh"
    fi

    [[ -n "${SPACE_TABLES[$s]}" ]] || fail_soft "$host: no tables listed for Genie space $space; grant table access by hand"
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      if [[ "$t" == *'`'* || "$(printf '%s' "$t" | tr -cd '.' | wc -c | tr -d ' ')" != 2 ]]; then
        fail_soft "$host: table identifier '$t' is not catalog.schema.table; grant it by hand"
        continue
      fi
      cat_name="${t%%.*}"
      schema_name="${t%.*}"
      for pair in "catalog|$cat_name|USE_CATALOG" "schema|$schema_name|USE_SCHEMA" "table|$t|SELECT"; do
        kind="${pair%%|*}"; rest="${pair#*|}"; full="${rest%|*}"; priv="${rest##*|}"
        once "uc|$host|$kind|$full" || continue
        body="{\"changes\":[{\"principal\":\"$ASCEND_APP\",\"add\":[\"$priv\"]}]}"
        if ! dbx_write "$host" grants update "$kind" "$full" --json "$body" >/dev/null; then
          if [[ "$cat_name" == "samples" ]]; then
            log "  $host: $priv on $full refused; fine, the built-in samples catalog is readable by everyone"
          else
            fail_soft "$host: $priv on $kind $full"
          fi
        fi
      done
    done <<<"${SPACE_TABLES[$s]}"
  done
fi

# ── Secrets (last, so a failed grant above does not strand a fresh secret) ───

section "OAuth secrets"
DISCOVER_SECRET=""
mint_secret "$DISCOVER_NAME" "${WS[0]}" "${DISCOVER_IDS[0]}" "$DISCOVER_SCOPES"
DISCOVER_SECRET="$SECRET_VALUE"
ASCEND_SECRET=""
if [[ -n "$ASCEND_APP" ]]; then
  mint_secret "$ASCEND_NAME" "${WS[$ASCEND_HOST_IDX]}" "$ASCEND_ID" "$ASCEND_SCOPES"
  ASCEND_SECRET="$SECRET_VALUE"
fi
SECRET_VALUE=""

# ── Output ───────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == 1 ]]; then
  printf '\nDry run complete: nothing was changed and no secret was created.\n'
  printf 'Re-run without --dry-run to apply, then paste the printed values into Straiker.\n'
  exit 0
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  log ""
  log "Some steps failed and need doing by hand (the values below still work once they are done):"
  for f in "${FAILURES[@]}"; do log "  - $f"; done
fi

{
  printf '\n==================== Paste into Straiker: Databricks ====================\n'
  printf 'Cloud\n  %s\n' "$CLOUD"
  printf 'Workspace URLs\n'
  for h in "${WS[@]}"; do printf '  %s\n' "$h"; done
  printf 'Databricks account ID\n  (optional; not needed by this script)\n'
  printf 'Discover service principal application ID  [discover_client_id]\n  %s\n' "$DISCOVER_APP"
  printf 'Discover secret  [discover_client_secret]\n  %s\n' "$DISCOVER_SECRET"
  if [[ -n "$ASCEND_APP" ]]; then
    printf 'Allow Ascend to send test prompts to Genie agents\n  tick it\n'
    printf 'Ascend service principal application ID  [ascend_client_id]\n  %s\n' "$ASCEND_APP"
    printf 'Ascend secret  [ascend_client_secret]\n  %s\n' "$ASCEND_SECRET"
  fi
  printf '=========================================================================\n'
  printf 'Secrets are shown once and were not saved anywhere. Copy them now.\n'
  if [[ "$DISCOVER_EXISTED" == 1 || "${ASCEND_EXISTED:-0}" == 1 ]]; then
    printf 'Existing principals were reused; older secrets were listed above for deletion.\n'
  fi
  if [[ -n "$ASCEND_APP" ]]; then
    printf 'Genie questions Ascend sends are billed to your Databricks workspace.\n'
  fi
}
DISCOVER_SECRET=""
ASCEND_SECRET=""

[[ ${#FAILURES[@]} -eq 0 ]] || exit 1
