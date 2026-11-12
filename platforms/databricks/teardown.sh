#!/usr/bin/env bash
# Straiker: remove the Databricks service principals that setup.sh created.
#
# Deletes each principal's OAuth secrets, then removes the principal from every workspace you
# name, which also drops its group memberships and the permissions granted to it there.
#
# Docs: https://github.com/straiker-ai/straiker-integrations/tree/main/platforms/databricks
set -euo pipefail

readonly HOST_RE='^https://[a-z0-9][a-z0-9.-]*\.(cloud\.databricks\.com|azuredatabricks\.net|gcp\.databricks\.com)$'

usage() {
  cat <<'EOF'
Usage: teardown.sh --workspaces URL[,URL...] (--profile NAME | --profile-map URL=NAME[,...])
                   [--discover-name NAME] [--ascend-name NAME] [--yes] [--dry-run] [--help]

Removes the Straiker service principals from the workspaces you name. Run it as a workspace
admin who is logged in with the Databricks CLI.

  --workspaces URL[,...]       Workspace URLs to remove the principals from. Required.
  --profile NAME               Databricks CLI profile used for every workspace.
  --profile-map URL=NAME,...   CLI profile per workspace.
  --discover-name NAME         Discover principal name (default: straiker-discover).
  --ascend-name NAME           Ascend principal name (default: straiker-ascend).
  --ascend-spaces ID[,...]     Accepted so setup.sh arguments can be reused; not needed.
  --yes                        Do not ask for confirmation.
  --dry-run                    Print what would be deleted; change nothing.
  -h, --help                   Show this help.

Straiker stops working for this connection as soon as the secrets are deleted. Remove the
integration in the Straiker console too.
EOF
}

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

WORKSPACES_ARG=""
DISCOVER_NAME="straiker-discover"
ASCEND_NAME="straiker-ascend"
PROFILE=""
PROFILE_MAP=""
YES=0
DRY_RUN=0

need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value (try --help)"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspaces) need_value "$@"; WORKSPACES_ARG="$2"; shift 2 ;;
    --workspaces=*) WORKSPACES_ARG="${1#*=}"; shift ;;
    --discover-name) need_value "$@"; DISCOVER_NAME="$2"; shift 2 ;;
    --discover-name=*) DISCOVER_NAME="${1#*=}"; shift ;;
    --ascend-name) need_value "$@"; ASCEND_NAME="$2"; shift 2 ;;
    --ascend-name=*) ASCEND_NAME="${1#*=}"; shift ;;
    --ascend-spaces) need_value "$@"; shift 2 ;;
    --ascend-spaces=*) shift ;;
    --profile) need_value "$@"; PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --profile-map) need_value "$@"; PROFILE_MAP="$2"; shift 2 ;;
    --profile-map=*) PROFILE_MAP="${1#*=}"; shift ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

norm_host() {
  local h
  h="$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  while [[ "$h" == */ ]]; do h="${h%/}"; done
  printf '%s' "$h"
}

split_csv() { printf '%s\n' "$1" | tr ',' '\n' | tr -d '[:blank:]' | sed '/^$/d'; }

[[ -n "$WORKSPACES_ARG" ]] || die "--workspaces is required (try --help)"
[[ -z "$PROFILE" || -z "$PROFILE_MAP" ]] || die "use --profile or --profile-map, not both"
[[ -n "$PROFILE" || -n "$PROFILE_MAP" ]] || die "--profile or --profile-map is required (try --help)"
for n in "$DISCOVER_NAME" "$ASCEND_NAME"; do
  [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "invalid service principal name: $n"
done

WS=()
while IFS= read -r raw; do
  h="$(norm_host "$raw")"
  [[ "$h" =~ $HOST_RE ]] || die "not a Databricks workspace URL: $raw"
  WS+=("$h")
done < <(split_csv "$WORKSPACES_ARG")
[[ ${#WS[@]} -gt 0 ]] || die "--workspaces contained no URL"

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

command -v databricks >/dev/null 2>&1 || die "the Databricks CLI is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

if profiles_json="$(databricks auth profiles --skip-validate -o json 2>/dev/null)"; then
  for h in "${WS[@]}"; do
    p="$(profile_for "$h")"
    ph="$(printf '%s' "$profiles_json" | jq -r --arg p "$p" '.profiles[]? | select(.name == $p) | .host' | head -n 1)"
    [[ -n "$ph" ]] || die "no Databricks CLI profile named '$p'. Run: databricks auth login --host $h --profile $p"
    [[ "$(norm_host "$ph")" == "$h" ]] || die "profile '$p' is for $(norm_host "$ph"), not $h. Use --profile-map."
  done
else
  log "warning: could not read Databricks CLI profiles; skipping the profile/host check"
fi

dbx() {
  local host="$1"; shift
  databricks "$@" --profile "$(profile_for "$host")"
}

# ── Find what to remove (read-only) ──────────────────────────────────────────

T_HOST=()
T_NAME=()
T_ID=()
T_APP=()
T_SECRETS=()
for h in "${WS[@]}"; do
  sps="$(dbx "$h" service-principals list -o json)" \
    || die "could not list service principals in $h (are you a workspace admin and logged in?)"
  for name in "$DISCOVER_NAME" "$ASCEND_NAME"; do
    while IFS=$'\t' read -r id app; do
      [[ -n "$id" ]] || continue
      secrets=""
      if sj="$(dbx "$h" service-principal-secrets-proxy list "$id" -o json 2>/dev/null)"; then
        secrets="$(printf '%s' "$sj" | jq -r '(if type == "array" then . else (.secrets // []) end)[]? | .id // empty' | tr '\n' ' ')"
      fi
      T_HOST+=("$h"); T_NAME+=("$name"); T_ID+=("$id"); T_APP+=("$app"); T_SECRETS+=("${secrets% }")
    done < <(printf '%s' "$sps" | jq -r --arg n "$name" '.[]? | select(.displayName == $n) | [.id, .applicationId] | @tsv')
  done
done

if [[ ${#T_ID[@]} -eq 0 ]]; then
  printf 'Nothing to remove: no service principal named %s or %s in the listed workspaces.\n' "$DISCOVER_NAME" "$ASCEND_NAME"
  exit 0
fi

printf 'Service principals to remove:\n'
for i in "${!T_ID[@]}"; do
  printf '  %s  %s  (ID %s, application ID %s, secrets: %s)\n' \
    "${T_HOST[$i]}" "${T_NAME[$i]}" "${T_ID[$i]}" "${T_APP[$i]}" "${T_SECRETS[$i]:-none listed}"
done

# OAuth secrets belong to the principal, not the workspace, so each is deleted once.
SEEN=""
first_time() {
  case "$SEEN" in *"|$1|"*) return 1 ;; esac
  SEEN="$SEEN|$1|"
}

if [[ "$DRY_RUN" == 1 ]]; then
  printf '\nDRY RUN: nothing will be changed. Commands that would run, in order:\n'
  for i in "${!T_ID[@]}"; do
    p="$(profile_for "${T_HOST[$i]}")"
    for s in ${T_SECRETS[$i]}; do
      first_time "${T_APP[$i]}|$s" || continue
      printf '  databricks service-principal-secrets-proxy delete %s %s --profile %s\n' "${T_ID[$i]}" "$s" "$p"
    done
    printf '  databricks service-principals delete %s --profile %s\n' "${T_ID[$i]}" "$p"
  done
  exit 0
fi

if [[ "$YES" != 1 ]]; then
  [[ -r /dev/tty ]] || die "no terminal to confirm on; pass --yes to proceed"
  printf '\nType "delete" to remove them: ' >&2
  read -r answer </dev/tty || answer=""
  [[ "$answer" == "delete" ]] || die "not confirmed; nothing was changed"
fi

FAILED=0
for i in "${!T_ID[@]}"; do
  h="${T_HOST[$i]}"
  for s in ${T_SECRETS[$i]}; do
    first_time "${T_APP[$i]}|$s" || continue
    if dbx "$h" service-principal-secrets-proxy delete "${T_ID[$i]}" "$s" >/dev/null; then
      log "  $h: deleted secret $s of ${T_NAME[$i]}"
    else
      log "  $h: could not delete secret $s of ${T_NAME[$i]}"; FAILED=1
    fi
  done
  if dbx "$h" service-principals delete "${T_ID[$i]}" >/dev/null; then
    log "  $h: removed ${T_NAME[$i]} (ID ${T_ID[$i]})"
  else
    log "  $h: could not remove ${T_NAME[$i]} (ID ${T_ID[$i]})"; FAILED=1
  fi
done

printf '\nDone. Remove the Databricks integration in the Straiker console as well.\n'
printf 'On identity-federated workspaces the principal may remain in your Databricks account;\n'
printf 'an account admin can delete it under User management > Service principals.\n'
exit "$FAILED"
