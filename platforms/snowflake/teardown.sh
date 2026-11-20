#!/usr/bin/env bash
# Straiker: remove the Snowflake users and roles that setup.sh created.
#
# Drops the Straiker service users first (their keys go with them, so Straiker loses access at
# once), then the Straiker roles, which removes every grant made to them, then Defend's STRAIKER_WH
# warehouse and STRAIKER_RM resource monitor if the setup created them. It never drops a warehouse
# passed to setup.sh with --warehouse, or one granted to Ascend with --ascend-warehouses.
#
# NOT YET VERIFIED LIVE: the Snowflake CLI calls and lookups in this script.
#
# Docs: https://github.com/straiker-ai/straiker-integrations/tree/main/platforms/snowflake
set -euo pipefail

readonly IDENT_RE='^[A-Za-z_][A-Za-z0-9_$]*$'
readonly ROLES=(STRAIKER_DISCOVER STRAIKER_DEFEND_MONITOR STRAIKER_ASCEND)
readonly DEDICATED_WH='STRAIKER_WH'
readonly DEDICATED_RM='STRAIKER_RM'
# The comment setup.sh (and the console's Defend setup SQL) gives the warehouse it creates.
readonly DEDICATED_WH_COMMENT='Straiker Defend trace reads (created by the Straiker setup)'

usage() {
  cat <<'EOF'
Usage: teardown.sh --connection NAME [--admin-role ROLE] [--discover-user NAME]
                   [--defend-user NAME] [--ascend-user NAME] [--drop-warehouse]
                   [--yes] [--dry-run] [--help]

Removes the Straiker service users and roles from the Snowflake account behind the connection.

  --connection NAME      Snowflake CLI connection. Required.
  --admin-role ROLE      Role that runs the SQL (default: ACCOUNTADMIN).
  --discover-user NAME   Discover user (default: STRAIKER_DISCOVER_SVC).
  --defend-user NAME     Defend user (default: STRAIKER_DEFEND_SVC).
  --ascend-user NAME     Ascend user (default: STRAIKER_ASCEND_SVC).
  --drop-warehouse       Also drop a STRAIKER_WH the setup did not create (it lacks the
                         setup's comment), and its STRAIKER_RM.
  --yes                  Do not ask for confirmation.
  --dry-run              Print what would be dropped; change nothing.
  -h, --help             Show this help.

Roles dropped: STRAIKER_DISCOVER, STRAIKER_DEFEND_MONITOR, STRAIKER_ASCEND. Roles you granted to
STRAIKER_ASCEND (--ascend-inherit-roles) are kept; only that grant goes.

Warehouse: the setup creates STRAIKER_WH only for Defend. It is dropped when the setup created it
(it carries the setup's comment), or with --drop-warehouse. STRAIKER_RM goes with it unless
another warehouse uses it or it is the account's monitor. A warehouse you passed to setup.sh with
--warehouse or --ascend-warehouses is never touched; dropping the roles removes their grants on it.

Straiker stops working for this account as soon as the users are dropped. Remove the integration
in the Straiker console too.
EOF
}

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

CONNECTION=""
ADMIN_ROLE="ACCOUNTADMIN"
DISCOVER_USER="STRAIKER_DISCOVER_SVC"
DEFEND_USER="STRAIKER_DEFEND_SVC"
ASCEND_USER="STRAIKER_ASCEND_SVC"
DROP_WAREHOUSE=0
YES=0
DRY_RUN=0

need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value (try --help)"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --connection) need_value "$@"; CONNECTION="$2"; shift 2 ;;
    --connection=*) CONNECTION="${1#*=}"; shift ;;
    --admin-role) need_value "$@"; ADMIN_ROLE="$2"; shift 2 ;;
    --admin-role=*) ADMIN_ROLE="${1#*=}"; shift ;;
    --discover-user) need_value "$@"; DISCOVER_USER="$2"; shift 2 ;;
    --discover-user=*) DISCOVER_USER="${1#*=}"; shift ;;
    --defend-user) need_value "$@"; DEFEND_USER="$2"; shift 2 ;;
    --defend-user=*) DEFEND_USER="${1#*=}"; shift ;;
    --ascend-user) need_value "$@"; ASCEND_USER="$2"; shift 2 ;;
    --ascend-user=*) ASCEND_USER="${1#*=}"; shift ;;
    --drop-warehouse) DROP_WAREHOUSE=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
ident() {
  [[ "$2" =~ $IDENT_RE ]] || die "$1: '$2' is not an unquoted Snowflake identifier"
  upper "$2"
}

[[ -n "$CONNECTION" ]] || die "--connection is required (try --help)"
ADMIN_ROLE="$(ident --admin-role "$ADMIN_ROLE")"
DISCOVER_USER="$(ident --discover-user "$DISCOVER_USER")"
DEFEND_USER="$(ident --defend-user "$DEFEND_USER")"
ASCEND_USER="$(ident --ascend-user "$ASCEND_USER")"

command -v snow >/dev/null 2>&1 || die "the Snowflake CLI is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

sf_rows() {
  local out
  out="$(snow sql -c "$CONNECTION" --role "$ADMIN_ROLE" --format json -q "$1" 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -c 'if type == "array" then map(if type == "object" then with_entries(.key |= ascii_downcase) else empty end) else [] end'
}

# ── Find what to remove (read-only) ──────────────────────────────────────────

# LIKE treats _ as a wildcard, so the exact name is matched in jq.
DROP_SQL=()
FOUND=()
for u in "$DISCOVER_USER" "$DEFEND_USER" "$ASCEND_USER"; do
  rows="$(sf_rows "SHOW USERS LIKE '$u'")" \
    || die "could not list users as $ADMIN_ROLE. Check the connection with: snow connection test -c $CONNECTION"
  type="$(printf '%s' "$rows" | jq -r --arg n "$u" '[.[] | select(.name == $n)][0] | if . == null then "" else ((.type // "PERSON") | tostring | ascii_upcase) end')"
  [[ -n "$type" ]] || continue
  if [[ "$type" != "SERVICE" ]]; then
    log "warning: user $u is not a service user (TYPE $type), so setup.sh did not create it; leaving it"
    continue
  fi
  FOUND+=("user $u")
  DROP_SQL+=("DROP USER IF EXISTS $u;")
done
for r in "${ROLES[@]}"; do
  rows="$(sf_rows "SHOW ROLES LIKE '$r'")" || die "could not list roles as $ADMIN_ROLE"
  [[ -n "$(printf '%s' "$rows" | jq -r --arg n "$r" '.[] | select(.name == $n) | .name')" ]] || continue
  FOUND+=("role $r")
  DROP_SQL+=("DROP ROLE IF EXISTS $r;")
done

# The warehouse after the users and roles, then its monitor: nothing still uses either by then.
KEPT=()
whs="$(sf_rows "SHOW WAREHOUSES")" || die "could not list warehouses as $ADMIN_ROLE"
wh_comment="$(printf '%s' "$whs" | jq -r --arg n "$DEDICATED_WH" '[.[] | select(.name == $n)][0] | if . == null then "<none>" else (.comment // "" | tostring) end')"
DROPPING_WH=0
if [[ "$wh_comment" != "<none>" ]]; then
  if [[ "$wh_comment" == "$DEDICATED_WH_COMMENT" || "$DROP_WAREHOUSE" == 1 ]]; then
    DROPPING_WH=1
    FOUND+=("warehouse $DEDICATED_WH")
    DROP_SQL+=("DROP WAREHOUSE IF EXISTS $DEDICATED_WH;")
  else
    KEPT+=("warehouse $DEDICATED_WH: the setup did not create it (pass --drop-warehouse to drop it anyway)")
  fi
fi
rms="$(sf_rows "SHOW RESOURCE MONITORS LIKE '$DEDICATED_RM'")" || die "could not list resource monitors as $ADMIN_ROLE"
rm_level="$(printf '%s' "$rms" | jq -r --arg n "$DEDICATED_RM" '[.[] | select(.name == $n)][0] | if . == null then "<none>" else (.level // "" | tostring | ascii_upcase) end')"
if [[ "$rm_level" != "<none>" ]]; then
  rm_users="$(printf '%s' "$whs" | jq -r --arg m "$DEDICATED_RM" --arg w "$DEDICATED_WH" '[.[] | select((.resource_monitor // "" | tostring) == $m and .name != $w) | .name] | join(", ")')"
  if [[ "$rm_level" == "ACCOUNT" ]]; then
    KEPT+=("resource monitor $DEDICATED_RM: it is the account's resource monitor")
  elif [[ -n "$rm_users" ]]; then
    KEPT+=("resource monitor $DEDICATED_RM: warehouse(s) $rm_users use it")
  elif [[ "$DROPPING_WH" == 1 || "$DROP_WAREHOUSE" == 1 ]]; then
    FOUND+=("resource monitor $DEDICATED_RM")
    DROP_SQL+=("DROP RESOURCE MONITOR IF EXISTS $DEDICATED_RM;")
  else
    KEPT+=("resource monitor $DEDICATED_RM: $DEDICATED_WH is kept (pass --drop-warehouse to drop both)")
  fi
fi

print_kept() {
  [[ ${#KEPT[@]} -gt 0 ]] || return 0
  printf 'Kept:\n'
  for k in "${KEPT[@]}"; do printf '  %s\n' "$k"; done
}

if [[ ${#DROP_SQL[@]} -eq 0 ]]; then
  print_kept
  printf 'Nothing to remove: no Straiker user, role, warehouse or resource monitor found.\n'
  exit 0
fi

printf 'Found:\n'
for f in "${FOUND[@]}"; do printf '  %s\n' "$f"; done
print_kept

if [[ "$DRY_RUN" == 1 ]]; then
  printf '\nDRY RUN: nothing will be changed. SQL that would run, in order (as %s):\n' "$ADMIN_ROLE"
  for s in "${DROP_SQL[@]}"; do printf '  %s\n' "$s"; done
  exit 0
fi

if [[ "$YES" != 1 ]]; then
  [[ -r /dev/tty ]] || die "no terminal to confirm on; pass --yes to proceed"
  printf '\nType "delete" to drop them: ' >&2
  read -r answer </dev/tty || answer=""
  [[ "$answer" == "delete" ]] || die "not confirmed; nothing was changed"
fi

# One statement per call, so one failure does not stop the rest.
FAILED=0
for s in "${DROP_SQL[@]}"; do
  if out="$(snow sql -c "$CONNECTION" --role "$ADMIN_ROLE" -q "$s" 2>&1)"; then
    log "  done: $s"
  else
    log "$out"
    log "  FAILED: $s"
    FAILED=1
  fi
done

printf '\nDone. Remove the Snowflake integration in the Straiker console as well.\n'
exit "$FAILED"
