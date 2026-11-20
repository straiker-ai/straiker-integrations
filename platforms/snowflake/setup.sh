#!/usr/bin/env bash
# Straiker: connect a Snowflake account (Discover, and optionally Defend trace monitoring and Ascend).
#
# Creates or reuses up to three Straiker service users, each with its own role and its own key
# pair, grants each role only what its product needs, and prints the values to paste into the
# Straiker console. With --defend, and unless --warehouse names an existing one, it also creates a
# dedicated X-Small warehouse for Defend's trace reads that suspends 60 seconds after its last
# query, with a monthly credit cap. Discover and Ascend get no Straiker warehouse. It runs SQL
# through the Snowflake CLI (snow sql) with your existing connection.
# Nothing is sent to Straiker and nothing is written to disk: private keys are generated in memory
# and printed once.
#
# NOT YET VERIFIED LIVE: the script end to end. The grants it issues were measured on a live
# account; the Snowflake CLI calls, the user, key and warehouse lookups, the key-slot rotation and
# the warehouse and resource monitor statements were not.
#
# Docs: https://github.com/straiker-ai/straiker-integrations/tree/main/platforms/snowflake
set -euo pipefail

readonly IDENT_RE='^[A-Za-z_][A-Za-z0-9_$]*$'
readonly FQN_RE='^[A-Za-z_][A-Za-z0-9_$]*\.[A-Za-z_][A-Za-z0-9_$]*\.[A-Za-z_][A-Za-z0-9_$]*$'
readonly SIG_RE='^[A-Za-z_][A-Za-z0-9_$]*\.[A-Za-z_][A-Za-z0-9_$]*\.[A-Za-z_][A-Za-z0-9_$]*\(( *[A-Za-z][A-Za-z0-9_ ]*(, *[A-Za-z][A-Za-z0-9_ ]*)*)?\)$'
readonly ADMIN_ROLES=' ACCOUNTADMIN SECURITYADMIN SYSADMIN USERADMIN ORGADMIN '
readonly DISCOVER_ROLE='STRAIKER_DISCOVER'
readonly DEFEND_ROLE='STRAIKER_DEFEND_MONITOR'
readonly ASCEND_ROLE='STRAIKER_ASCEND'
readonly DEDICATED_WH='STRAIKER_WH'
readonly DEDICATED_RM='STRAIKER_RM'
# teardown.sh drops STRAIKER_WH only when it carries this comment, so keep the two in step.
readonly DEDICATED_WH_COMMENT='Straiker Defend trace reads (created by the Straiker setup)'
readonly DEFAULT_CREDIT_QUOTA=100
readonly QUOTA_RE='^[1-9][0-9]{0,5}$'

usage() {
  cat <<'EOF'
Usage: setup.sh --databases DB[,DB...] --connection NAME
                [--defend [--warehouse NAME | --credit-quota N]]
                [--ascend-agents DB.SCHEMA.AGENT[,...] [--ascend-tables ...] [--ascend-views ...]
                 [--ascend-semantic-views ...] [--ascend-search-services ...]
                 [--ascend-procedure 'DB.SCHEMA.NAME(TYPE, ...)']... [--ascend-function ...]...
                 [--ascend-warehouses WH[,...]] [--ascend-inherit-roles ROLE[,...]]]
                [--admin-role ROLE] [--discover-user NAME] [--defend-user NAME]
                [--ascend-user NAME] [--rotate-keys] [--dry-run] [--help]

Grants Straiker access to one Snowflake account. Run it with a Snowflake CLI connection whose user
may use ACCOUNTADMIN (or the role given with --admin-role).

  --connection NAME             Snowflake CLI connection (snow connection add). Required, except
                                with --dry-run (without it the plan assumes nothing exists yet).
  --admin-role ROLE             Role that runs the SQL (default: ACCOUNTADMIN).
  --databases DB[,...]          Every database that holds Cortex Agents. Required. Discover (and
                                Defend) see agents only in these databases.
  --defend                      Also create the Defend trace-monitoring user, and its warehouse.
  --warehouse NAME              With --defend: an existing warehouse for Defend's trace reads.
                                Without it, the script creates STRAIKER_WH (X-Small,
                                AUTO_SUSPEND = 60) with the resource monitor STRAIKER_RM.
  --credit-quota N              With --defend: STRAIKER_RM's monthly credit quota (default: 100).
                                It notifies at 80% and suspends STRAIKER_WH at 100%. Not with
                                --warehouse.
  --ascend-agents FQN[,...]     Cortex Agents Ascend may test (DB.SCHEMA.AGENT). Creates the
                                Ascend user. Every --ascend-* option below needs this one.
  --ascend-tables FQN[,...]     Tables those agents read with the caller's rights (SELECT).
  --ascend-views FQN[,...]      Views they read (SELECT).
  --ascend-semantic-views FQN[,...]   Semantic views their Cortex Analyst tools use (SELECT).
  --ascend-search-services FQN[,...]  Cortex Search services they query (USAGE).
  --ascend-procedure SIG        A procedure tool, as DB.SCHEMA.NAME(TYPE, ...) (USAGE). Repeatable.
  --ascend-function SIG         A function tool, same form (USAGE). Repeatable.
  --ascend-warehouses WH[,...]  The warehouses those tools run on (USAGE): each tool's
                                execution_environment warehouse, under tool_resources in the
                                agent_spec that DESCRIBE AGENT shows. Ascend gets no other one.
  --ascend-inherit-roles R[,...]  Existing roles to grant to the Ascend role, to test as those
                                users. Admin roles are refused.
  --discover-user NAME          Discover user (default: STRAIKER_DISCOVER_SVC).
  --defend-user NAME            Defend user (default: STRAIKER_DEFEND_SVC).
  --ascend-user NAME            Ascend user (default: STRAIKER_ASCEND_SVC).
  --rotate-keys                 Give users that already have a key a new one, in their free key
                                slot, and print the SQL to retire the old one.
  --dry-run                     Print the SQL that would run, as a script you could also paste
                                into a Snowsight worksheet; change nothing and create no key.
  -h, --help                    Show this help.

Names are unquoted Snowflake identifiers and are upper-cased. Roles are STRAIKER_DISCOVER,
STRAIKER_DEFEND_MONITOR and STRAIKER_ASCEND.

What it does:
  Discover: per database, USAGE on the database and its schemas, MONITOR on agents and Cortex
  Search services, REFERENCES on semantic views and USAGE on MCP servers (ALL and FUTURE). It runs
  only SHOW and DESCRIBE, so it gets no warehouse. It cannot read a table, run an agent, call a
  procedure or read conversations.
  Defend (--defend): MONITOR on agents per database, READ UNREDACTED AI OBSERVABILITY EVENTS TABLE
  on the account, and USAGE on its warehouse: without --warehouse, a dedicated STRAIKER_WH
  (X-Small, suspends 60 seconds after its last query) capped by STRAIKER_RM. An existing
  STRAIKER_WH or STRAIKER_RM is not changed. It cannot read a table or run an agent.
  Ascend (--ascend-agents): USAGE on the agents you name, what their tools act on and the
  warehouses those tools run on. Agents run tools with the caller's rights, so write tools run
  for real; each probe is billed to you.

Output: the values to paste into Straiker, printed once to stdout. A user that already has a key
keeps it (Straiker keeps using it) unless you pass --rotate-keys.
EOF
}

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

CONNECTION=""
ADMIN_ROLE="ACCOUNTADMIN"
WAREHOUSE=""
CREDIT_QUOTA=""
DATABASES_ARG=""
DEFEND=0
ASCEND_AGENTS_ARG=""
ASCEND_TABLES_ARG=""
ASCEND_VIEWS_ARG=""
ASCEND_SV_ARG=""
ASCEND_SEARCH_ARG=""
ASCEND_WH_ARG=""
ASCEND_ROLES_ARG=""
ASCEND_PROCS_RAW=()
ASCEND_FUNCS_RAW=()
DISCOVER_USER="STRAIKER_DISCOVER_SVC"
DEFEND_USER="STRAIKER_DEFEND_SVC"
ASCEND_USER="STRAIKER_ASCEND_SVC"
ROTATE=0
DRY_RUN=0

need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value (try --help)"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --connection) need_value "$@"; CONNECTION="$2"; shift 2 ;;
    --connection=*) CONNECTION="${1#*=}"; shift ;;
    --admin-role) need_value "$@"; ADMIN_ROLE="$2"; shift 2 ;;
    --admin-role=*) ADMIN_ROLE="${1#*=}"; shift ;;
    --warehouse) need_value "$@"; WAREHOUSE="$2"; shift 2 ;;
    --warehouse=*) WAREHOUSE="${1#*=}"; shift ;;
    --credit-quota) need_value "$@"; CREDIT_QUOTA="$2"; shift 2 ;;
    --credit-quota=*) CREDIT_QUOTA="${1#*=}"; shift ;;
    --databases) need_value "$@"; DATABASES_ARG="$2"; shift 2 ;;
    --databases=*) DATABASES_ARG="${1#*=}"; shift ;;
    --defend) DEFEND=1; shift ;;
    --ascend-agents) need_value "$@"; ASCEND_AGENTS_ARG="$2"; shift 2 ;;
    --ascend-agents=*) ASCEND_AGENTS_ARG="${1#*=}"; shift ;;
    --ascend-tables) need_value "$@"; ASCEND_TABLES_ARG="$2"; shift 2 ;;
    --ascend-tables=*) ASCEND_TABLES_ARG="${1#*=}"; shift ;;
    --ascend-views) need_value "$@"; ASCEND_VIEWS_ARG="$2"; shift 2 ;;
    --ascend-views=*) ASCEND_VIEWS_ARG="${1#*=}"; shift ;;
    --ascend-semantic-views) need_value "$@"; ASCEND_SV_ARG="$2"; shift 2 ;;
    --ascend-semantic-views=*) ASCEND_SV_ARG="${1#*=}"; shift ;;
    --ascend-search-services) need_value "$@"; ASCEND_SEARCH_ARG="$2"; shift 2 ;;
    --ascend-search-services=*) ASCEND_SEARCH_ARG="${1#*=}"; shift ;;
    --ascend-procedure) need_value "$@"; ASCEND_PROCS_RAW+=("$2"); shift 2 ;;
    --ascend-procedure=*) ASCEND_PROCS_RAW+=("${1#*=}"); shift ;;
    --ascend-function) need_value "$@"; ASCEND_FUNCS_RAW+=("$2"); shift 2 ;;
    --ascend-function=*) ASCEND_FUNCS_RAW+=("${1#*=}"); shift ;;
    --ascend-warehouses) need_value "$@"; ASCEND_WH_ARG="$2"; shift 2 ;;
    --ascend-warehouses=*) ASCEND_WH_ARG="${1#*=}"; shift ;;
    --ascend-inherit-roles) need_value "$@"; ASCEND_ROLES_ARG="$2"; shift 2 ;;
    --ascend-inherit-roles=*) ASCEND_ROLES_ARG="${1#*=}"; shift ;;
    --discover-user) need_value "$@"; DISCOVER_USER="$2"; shift 2 ;;
    --discover-user=*) DISCOVER_USER="${1#*=}"; shift ;;
    --defend-user) need_value "$@"; DEFEND_USER="$2"; shift 2 ;;
    --defend-user=*) DEFEND_USER="${1#*=}"; shift ;;
    --ascend-user) need_value "$@"; ASCEND_USER="$2"; shift 2 ;;
    --ascend-user=*) ASCEND_USER="${1#*=}"; shift ;;
    --rotate-keys) ROTATE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ── Input validation ─────────────────────────────────────────────────────────

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
split_csv() { printf '%s\n' "$1" | tr ',' '\n' | tr -d '[:blank:]' | sed '/^$/d'; }

# Every name lands in SQL text, so each is checked against the unquoted-identifier grammar first.
ident() {
  [[ "$2" =~ $IDENT_RE ]] || die "$1: '$2' is not an unquoted Snowflake identifier (letters, digits, _ and \$)"
  upper "$2"
}

[[ -n "$DATABASES_ARG" ]] || die "--databases is required (try --help)"
[[ -n "$CONNECTION" || "$DRY_RUN" == 1 ]] || die "--connection is required (try --help)"
ADMIN_ROLE="$(ident --admin-role "$ADMIN_ROLE")"
# Only Defend's trace reads need a Straiker warehouse: Discover runs SHOW and DESCRIBE, and Ascend
# makes REST calls whose tools run on the warehouses in --ascend-warehouses.
if [[ "$DEFEND" != 1 ]] && [[ -n "$WAREHOUSE" || -n "$CREDIT_QUOTA" ]]; then
  die "--warehouse and --credit-quota set up Defend's warehouse, so they need --defend. Discover needs no warehouse; the warehouses Ascend's tools run on go in --ascend-warehouses"
fi
OWN_WAREHOUSE=0
if [[ "$DEFEND" == 1 && -n "$WAREHOUSE" ]]; then
  OWN_WAREHOUSE=1
  WAREHOUSE="$(ident --warehouse "$WAREHOUSE")"
  [[ -z "$CREDIT_QUOTA" ]] || die "--credit-quota sets the cap on STRAIKER_WH, which --warehouse replaces; use one or the other"
elif [[ "$DEFEND" == 1 ]]; then
  WAREHOUSE="$DEDICATED_WH"
  CREDIT_QUOTA="${CREDIT_QUOTA:-$DEFAULT_CREDIT_QUOTA}"
  [[ "$CREDIT_QUOTA" =~ $QUOTA_RE ]] || die "--credit-quota: '$CREDIT_QUOTA' is not a whole number of credits from 1 to 999999"
  # Snowflake lets only ACCOUNTADMIN create a resource monitor.
  [[ "$ADMIN_ROLE" == "ACCOUNTADMIN" ]] \
    || die "creating the STRAIKER_RM resource monitor for Defend's warehouse needs ACCOUNTADMIN. Run as ACCOUNTADMIN, or pass --warehouse with an existing warehouse"
fi
DISCOVER_USER="$(ident --discover-user "$DISCOVER_USER")"
DEFEND_USER="$(ident --defend-user "$DEFEND_USER")"
ASCEND_USER="$(ident --ascend-user "$ASCEND_USER")"
[[ "$DISCOVER_USER" != "$DEFEND_USER" && "$DISCOVER_USER" != "$ASCEND_USER" && "$DEFEND_USER" != "$ASCEND_USER" ]] \
  || die "the Discover, Defend and Ascend users must be three different users (one key must never sign in as two)"

DATABASES=()
while IFS= read -r d; do
  d="$(ident --databases "$d")"
  for seen in ${DATABASES[@]+"${DATABASES[@]}"}; do [[ "$seen" != "$d" ]] || die "database listed twice: $d"; done
  DATABASES+=("$d")
done < <(split_csv "$DATABASES_ARG")
[[ ${#DATABASES[@]} -gt 0 ]] || die "--databases contained no name"

# read_fqns FLAG CSV sets FQNS to the validated, upper-cased DB.SCHEMA.NAME values.
FQNS=()
read_fqns() {
  local x
  FQNS=()
  while IFS= read -r x; do
    [[ "$x" =~ $FQN_RE ]] || die "$1: '$x' is not DATABASE.SCHEMA.NAME of unquoted identifiers (grant quoted names by hand)"
    FQNS+=("$(upper "$x")")
  done < <(split_csv "$2")
}
read_fqns --ascend-agents "$ASCEND_AGENTS_ARG"; AGENTS=(${FQNS[@]+"${FQNS[@]}"})
read_fqns --ascend-tables "$ASCEND_TABLES_ARG"; TABLES=(${FQNS[@]+"${FQNS[@]}"})
read_fqns --ascend-views "$ASCEND_VIEWS_ARG"; VIEWS=(${FQNS[@]+"${FQNS[@]}"})
read_fqns --ascend-semantic-views "$ASCEND_SV_ARG"; SEMVIEWS=(${FQNS[@]+"${FQNS[@]}"})
read_fqns --ascend-search-services "$ASCEND_SEARCH_ARG"; SEARCHES=(${FQNS[@]+"${FQNS[@]}"})

PROCS=()
for p in ${ASCEND_PROCS_RAW[@]+"${ASCEND_PROCS_RAW[@]}"}; do
  [[ "$p" =~ $SIG_RE ]] || die "--ascend-procedure: '$p' is not DB.SCHEMA.NAME(TYPE, ...)"
  PROCS+=("$(upper "$p")")
done
FUNCS=()
for f in ${ASCEND_FUNCS_RAW[@]+"${ASCEND_FUNCS_RAW[@]}"}; do
  [[ "$f" =~ $SIG_RE ]] || die "--ascend-function: '$f' is not DB.SCHEMA.NAME(TYPE, ...)"
  FUNCS+=("$(upper "$f")")
done

ASCEND_WHS=()
while IFS= read -r w; do
  w="$(ident --ascend-warehouses "$w")"
  ASCEND_WHS+=("$w")
done < <(split_csv "$ASCEND_WH_ARG")
INHERIT_ROLES=()
while IFS= read -r r; do
  r="$(ident --ascend-inherit-roles "$r")"
  [[ "$ADMIN_ROLES" != *" $r "* ]] || die "--ascend-inherit-roles: $r is an admin role; Ascend must test as an ordinary user"
  [[ "$r" != "$DISCOVER_ROLE" && "$r" != "$DEFEND_ROLE" && "$r" != "$ASCEND_ROLE" ]] || die "--ascend-inherit-roles: $r is a Straiker role"
  INHERIT_ROLES+=("$r")
done < <(split_csv "$ASCEND_ROLES_ARG")

ASCEND=0
[[ ${#AGENTS[@]} -eq 0 ]] || ASCEND=1
if [[ "$ASCEND" == 0 ]] && [[ ${#TABLES[@]} -gt 0 || ${#VIEWS[@]} -gt 0 || ${#SEMVIEWS[@]} -gt 0 || ${#SEARCHES[@]} -gt 0 \
  || ${#PROCS[@]} -gt 0 || ${#FUNCS[@]} -gt 0 || ${#ASCEND_WHS[@]} -gt 0 || ${#INHERIT_ROLES[@]} -gt 0 ]]; then
  die "the --ascend-* options need --ascend-agents (the agents Ascend may test)"
fi
if [[ "$ASCEND" == 1 && ${#ASCEND_WHS[@]} -eq 0 ]]; then
  log "warning: no --ascend-warehouses. A tool that runs SQL (Cortex Analyst, a procedure or a function)"
  log "  runs on the warehouse in its execution_environment, and fails for Ascend without USAGE on it."
  log "  DESCRIBE AGENT <agent> shows it in agent_spec, under tool_resources. Name each one with"
  log "  --ascend-warehouses. Agents that only use Cortex Search need none."
fi

LOOKUPS=0
if [[ -n "$CONNECTION" ]]; then
  LOOKUPS=1
  command -v snow >/dev/null 2>&1 || die "the Snowflake CLI is required (https://docs.snowflake.com/en/developer-guide/snowflake-cli/installation/installation)"
  command -v jq >/dev/null 2>&1 || die "jq is required (https://jqlang.org/download/)"
fi
if [[ "$DRY_RUN" != 1 ]]; then
  command -v openssl >/dev/null 2>&1 || die "openssl is required to generate the key pairs"
fi

# ── Snowflake helpers ────────────────────────────────────────────────────────

# One read-only statement; prints its rows as a JSON array with lower-case column names.
sf_rows() {
  local out
  out="$(snow sql -c "$CONNECTION" --role "$ADMIN_ROLE" --format json -q "$1" 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -c 'if type == "array" then map(if type == "object" then with_entries(.key |= ascii_downcase) else empty end) else [] end'
}

# Runs a SQL script in one session. snow's result tables are shown only when it fails.
sf_run() {
  local out
  if ! out="$(printf '%s' "$1" | snow sql -c "$CONNECTION" --role "$ADMIN_ROLE" --stdin 2>&1)"; then
    log "$out"
    return 1
  fi
}

# user_state NAME sets U_EXISTS (0/1), U_TYPE, U_FP1, U_FP2 (key fingerprints, empty when unset).
U_EXISTS=0; U_TYPE=""; U_FP1=""; U_FP2=""
user_state() {
  local name="$1" rows desc
  U_EXISTS=0; U_TYPE=""; U_FP1=""; U_FP2=""
  # LIKE treats _ as a wildcard, so the exact name is matched in jq.
  rows="$(sf_rows "SHOW USERS LIKE '$name'")" || return 1
  U_TYPE="$(printf '%s' "$rows" | jq -r --arg n "$name" '[.[] | select(.name == $n)][0] | if . == null then "" else ((.type // "PERSON") | tostring | ascii_upcase) end')"
  [[ -n "$U_TYPE" ]] || return 0
  U_EXISTS=1
  desc="$(sf_rows "DESC USER $name")" || return 1
  U_FP1="$(printf '%s' "$desc" | jq -r '[.[] | select(.property == "RSA_PUBLIC_KEY_FP") | .value][0] // "" | tostring | if . == "null" then "" else . end')"
  U_FP2="$(printf '%s' "$desc" | jq -r '[.[] | select(.property == "RSA_PUBLIC_KEY_2_FP") | .value][0] // "" | tostring | if . == "null" then "" else . end')"
}

# warehouse_state NAME sets W_EXISTS (0/1), W_SIZE (XSMALL form), W_SUSPEND (seconds, empty when
# it never suspends), W_RESUME and W_MONITOR (empty when none).
W_EXISTS=0; W_SIZE=""; W_SUSPEND=""; W_RESUME=""; W_MONITOR=""
warehouse_state() {
  local name="$1" rows line
  W_EXISTS=0; W_SIZE=""; W_SUSPEND=""; W_RESUME=""; W_MONITOR=""
  rows="$(sf_rows "SHOW WAREHOUSES LIKE '$name'")" || return 1
  line="$(printf '%s' "$rows" | jq -r --arg n "$name" '
    def text: if . == null then "" else tostring end | if ascii_downcase == "null" then "" else . end;
    [.[] | select(.name == $n)][0] | if . == null then "" else
      ["1", (.size | text | ascii_upcase | gsub("[^A-Z0-9]"; "")), (.auto_suspend | text),
       (.auto_resume | text | ascii_downcase), (.resource_monitor | text)] | join("|") end')"
  [[ -n "$line" ]] || return 0
  IFS='|' read -r W_EXISTS W_SIZE W_SUSPEND W_RESUME W_MONITOR <<<"$line"
  [[ "$W_SUSPEND" != "0" ]] || W_SUSPEND=""
}

# ── Plan the users and their keys ────────────────────────────────────────────

# Products in the console's order. KEY_SLOT is the user property a new key goes into (empty: the
# user keeps its key); RETIRE_SLOT is the one to unset once Straiker uses the new key.
P_LABEL=(Discover)
P_USER=("$DISCOVER_USER")
P_ROLE=("$DISCOVER_ROLE")
if [[ "$ASCEND" == 1 ]]; then P_LABEL+=(Ascend); P_USER+=("$ASCEND_USER"); P_ROLE+=("$ASCEND_ROLE"); fi
if [[ "$DEFEND" == 1 ]]; then P_LABEL+=(Defend); P_USER+=("$DEFEND_USER"); P_ROLE+=("$DEFEND_ROLE"); fi
P_SLOT=(); P_RETIRE=(); P_NOTE=()

ACCOUNT="<org>-<account>"
if [[ "$LOOKUPS" == 1 ]]; then
  if acct_rows="$(sf_rows "SELECT CURRENT_ORGANIZATION_NAME() AS ORG_NAME, CURRENT_ACCOUNT_NAME() AS ACCOUNT_NAME")"; then
    ACCOUNT="$(printf '%s' "$acct_rows" | jq -r '.[0] | "\(.org_name // "")-\(.account_name // "")"' | tr '[:upper:]' '[:lower:]')"
    [[ "$ACCOUNT" != "-" && -n "$ACCOUNT" ]] || ACCOUNT="<org>-<account>"
  else
    die "could not query Snowflake with connection '$CONNECTION' as $ADMIN_ROLE. Check it with: snow connection test -c $CONNECTION"
  fi
fi

for i in "${!P_USER[@]}"; do
  u="${P_USER[$i]}"
  P_SLOT[i]="RSA_PUBLIC_KEY"; P_RETIRE[i]=""; P_NOTE[i]="new user; its key goes in RSA_PUBLIC_KEY"
  [[ "$LOOKUPS" == 1 ]] || { P_NOTE[i]="assumed new (no --connection, so nothing was looked up)"; continue; }
  user_state "$u" || die "could not look up user $u as $ADMIN_ROLE"
  [[ "$U_EXISTS" == 1 ]] || continue
  [[ "$U_TYPE" == "SERVICE" ]] || die "user $u exists and is not a service user (TYPE $U_TYPE); choose another name with --$(printf '%s' "${P_LABEL[$i]}" | tr '[:upper:]' '[:lower:]')-user"
  if [[ -z "$U_FP1" && -z "$U_FP2" ]]; then
    P_NOTE[i]="existing user without a key; its key goes in RSA_PUBLIC_KEY"
  elif [[ "$ROTATE" != 1 ]]; then
    P_SLOT[i]=""; P_NOTE[i]="existing user with a key; it keeps that key (use --rotate-keys for a new one)"
  elif [[ -z "$U_FP2" ]]; then
    P_SLOT[i]="RSA_PUBLIC_KEY_2"; P_RETIRE[i]="RSA_PUBLIC_KEY"
    P_NOTE[i]="rotating: new key in RSA_PUBLIC_KEY_2, current key ($U_FP1) stays until you retire it"
  elif [[ -z "$U_FP1" ]]; then
    P_SLOT[i]="RSA_PUBLIC_KEY"; P_RETIRE[i]="RSA_PUBLIC_KEY_2"
    P_NOTE[i]="rotating: new key in RSA_PUBLIC_KEY, current key ($U_FP2) stays until you retire it"
  else
    die "user $u already has two keys ($U_FP1, $U_FP2). Unset the one Straiker does not use (ALTER USER $u UNSET RSA_PUBLIC_KEY or RSA_PUBLIC_KEY_2), then re-run"
  fi
done

# ── Plan Defend's warehouse ──────────────────────────────────────────────────

# Without --connection nothing can be looked up, so the warning cannot name the setting.
warn_own_warehouse() {
  log "warning: Straiker's Defend trace polling wakes warehouse $WAREHOUSE on a schedule, and"
  log "  Snowflake bills at least 60 seconds per wake."
  log "  $1"
  log "  Recommended: ALTER WAREHOUSE $WAREHOUSE SET AUTO_SUSPEND = 60; or omit --warehouse to use a"
  log "  dedicated X-Small $DEDICATED_WH. See the README's cost section."
}

if [[ "$DEFEND" != 1 ]]; then
  WH_NOTE="none (Defend is off; Discover runs only SHOW and DESCRIBE)"
elif [[ "$OWN_WAREHOUSE" == 1 ]]; then
  WH_NOTE="Defend uses the existing warehouse $WAREHOUSE"
  if [[ "$LOOKUPS" != 1 ]]; then
    warn_own_warehouse "Its AUTO_SUSPEND was not checked (no --connection); at Snowflake's default of 600 seconds it stays up most of the day."
  else
    warehouse_state "$WAREHOUSE" || die "could not look up warehouse $WAREHOUSE as $ADMIN_ROLE"
    [[ "$W_EXISTS" == 1 ]] || die "warehouse $WAREHOUSE does not exist or $ADMIN_ROLE cannot see it. Omit --warehouse to create $DEDICATED_WH"
    WH_NOTE="$WH_NOTE, auto-suspend ${W_SUSPEND:-never}"
    if [[ -z "$W_SUSPEND" ]]; then
      warn_own_warehouse "It never auto-suspends, so once woken it runs until someone suspends it."
    elif [[ ! "$W_SUSPEND" =~ ^[0-9]+$ ]]; then
      warn_own_warehouse "Its AUTO_SUSPEND could not be read ('$W_SUSPEND')."
    elif [[ "$W_SUSPEND" -gt 60 ]]; then
      warn_own_warehouse "Its AUTO_SUSPEND is $W_SUSPEND seconds, so each wake bills at least that long."
    fi
  fi
else
  WH_NOTE="Defend uses $DEDICATED_WH (X-Small, AUTO_SUSPEND = 60) with $DEDICATED_RM ($CREDIT_QUOTA credits a month), created if missing"
  if [[ "$LOOKUPS" != 1 ]]; then
    WH_NOTE="$WH_NOTE (no --connection, so nothing was looked up)"
  else
    warehouse_state "$DEDICATED_WH" || die "could not look up warehouse $DEDICATED_WH as $ADMIN_ROLE"
    if [[ "$W_EXISTS" == 1 ]]; then
      if [[ -n "$W_MONITOR" && "$W_MONITOR" != "$DEDICATED_RM" ]]; then
        die "warehouse $DEDICATED_WH already exists with resource monitor $W_MONITOR, which this script would replace with $DEDICATED_RM. To keep it as it is, pass --warehouse $DEDICATED_WH"
      fi
      WH_NOTE="Defend uses $DEDICATED_WH, which exists and keeps its settings"
      if [[ "$W_SIZE" != "XSMALL" || "$W_SUSPEND" != "60" || "$W_RESUME" != "true" ]]; then
        log "warning: warehouse $DEDICATED_WH already exists with size ${W_SIZE:-unknown}, auto-suspend ${W_SUSPEND:-never}"
        log "  and auto-resume ${W_RESUME:-unknown}. The script does not change it. For the recommended setup, run:"
        log "  ALTER WAREHOUSE $DEDICATED_WH SET WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE;"
        WH_NOTE="$WH_NOTE, which differ from the recommended ones (see the warning)"
      fi
      WH_NOTE="$WH_NOTE; $DEDICATED_RM ($CREDIT_QUOTA credits a month) is created if missing"
    fi
    rm_rows="$(sf_rows "SHOW RESOURCE MONITORS LIKE '$DEDICATED_RM'")" \
      || die "could not look up resource monitor $DEDICATED_RM as $ADMIN_ROLE"
    # Prints nothing when the monitor is missing, "same" when its quota matches, else its quota.
    rm_quota="$(printf '%s' "$rm_rows" | jq -r --arg n "$DEDICATED_RM" --argjson q "$CREDIT_QUOTA" '
      [.[] | select(.name == $n)][0] | if . == null then "" else
        (.credit_quota | if . == null then "none" else tostring end) as $c
        | if ($c | tonumber? // null) == $q then "same" else $c end end')"
    if [[ -n "$rm_quota" && "$rm_quota" != "same" ]]; then
      log "warning: resource monitor $DEDICATED_RM already exists with a credit quota of $rm_quota, not $CREDIT_QUOTA."
      log "  The script does not change it. To apply $CREDIT_QUOTA, run:"
      log "  ALTER RESOURCE MONITOR $DEDICATED_RM SET CREDIT_QUOTA = $CREDIT_QUOTA;"
      WH_NOTE="$WH_NOTE; $DEDICATED_RM exists with a quota of $rm_quota and is kept"
    fi
  fi
fi

# ── Build the SQL ────────────────────────────────────────────────────────────

SQL=""
emit() { SQL="${SQL}$*"$'\n'; }
DONE_KEYS=""
once() {
  case "$DONE_KEYS" in *"|$1|"*) return 1 ;; esac
  DONE_KEYS="$DONE_KEYS|$1|"
}

# Per-database MONITOR grants: Snowflake has no account-wide read-only grant on agents, so a
# database left out here stays invisible. ALL covers what exists now, FUTURE what comes later.
grant_database_monitor() {
  local role="$1" db="$2" full="$3"
  emit "-- Database $db"
  emit "GRANT USAGE ON DATABASE $db TO ROLE $role;"
  emit "GRANT USAGE ON ALL SCHEMAS IN DATABASE $db TO ROLE $role;"
  emit "GRANT USAGE ON FUTURE SCHEMAS IN DATABASE $db TO ROLE $role;"
  emit "GRANT MONITOR ON ALL AGENTS IN DATABASE $db TO ROLE $role;"
  emit "GRANT MONITOR ON FUTURE AGENTS IN DATABASE $db TO ROLE $role;"
  [[ "$full" == 1 ]] || return 0
  emit "GRANT MONITOR ON ALL CORTEX SEARCH SERVICES IN DATABASE $db TO ROLE $role;"
  emit "GRANT MONITOR ON FUTURE CORTEX SEARCH SERVICES IN DATABASE $db TO ROLE $role;"
  emit "GRANT REFERENCES ON ALL SEMANTIC VIEWS IN DATABASE $db TO ROLE $role;"
  emit "GRANT REFERENCES ON FUTURE SEMANTIC VIEWS IN DATABASE $db TO ROLE $role;"
  emit "-- MCP servers have no read-only privilege: USAGE lists and describes them but calls no tool."
  emit "GRANT USAGE ON ALL MCP SERVERS IN DATABASE $db TO ROLE $role;"
  emit "GRANT USAGE ON FUTURE MCP SERVERS IN DATABASE $db TO ROLE $role;"
}

# service_user USER ROLE COMMENT [WAREHOUSE]: only Defend's user has a default warehouse.
# DEFAULT_SECONDARY_ROLES = () keeps only the user's own role active: a role granted to it later stays off.
service_user() {
  local user="$1" role="$2" comment="$3" defaults="DEFAULT_ROLE = $2 DEFAULT_SECONDARY_ROLES = ()"
  [[ -z "${4:-}" ]] || defaults="$defaults DEFAULT_WAREHOUSE = $4"
  emit "CREATE USER IF NOT EXISTS $user TYPE = SERVICE $defaults"
  emit "  COMMENT = '$comment';"
  emit "ALTER USER $user SET $defaults;"
  emit "GRANT ROLE $role TO USER $user;"
}

# The console's Defend setup SQL emits this same block (frontend setup-sql.ts): keep them identical.
dedicated_warehouse() {
  emit "-- Warehouse $DEDICATED_WH: Defend's trace reads only, X-Small, suspends 60 seconds after its last query."
  emit "-- Resource monitor $DEDICATED_RM: notifies at 80% of $CREDIT_QUOTA credits a month, suspends $DEDICATED_WH at 100%."
  emit "-- An existing $DEDICATED_WH keeps its size and auto-suspend; an existing $DEDICATED_RM keeps its quota."
  emit "CREATE WAREHOUSE IF NOT EXISTS $DEDICATED_WH WITH WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60"
  emit "  AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE"
  emit "  COMMENT = '$DEDICATED_WH_COMMENT';"
  emit "CREATE RESOURCE MONITOR IF NOT EXISTS $DEDICATED_RM WITH CREDIT_QUOTA = $CREDIT_QUOTA FREQUENCY = MONTHLY"
  emit "  START_TIMESTAMP = IMMEDIATELY TRIGGERS ON 80 PERCENT DO NOTIFY ON 100 PERCENT DO SUSPEND;"
  emit "ALTER WAREHOUSE $DEDICATED_WH SET RESOURCE_MONITOR = $DEDICATED_RM;"
}

emit "USE ROLE $ADMIN_ROLE;"
emit ""
emit "-- Discover: $DISCOVER_USER -> $DISCOVER_ROLE. Read-only inventory of Cortex Agents."
emit "-- It runs only SHOW and DESCRIBE, which need no warehouse, so it has none."
emit "CREATE ROLE IF NOT EXISTS $DISCOVER_ROLE COMMENT = 'Straiker Discover: read-only inventory of Cortex Agents';"
for db in "${DATABASES[@]}"; do grant_database_monitor "$DISCOVER_ROLE" "$db" 1; done
service_user "$DISCOVER_USER" "$DISCOVER_ROLE" 'Straiker Discover (read-only)'

if [[ "$DEFEND" == 1 ]]; then
  emit ""
  emit "-- Defend: $DEFEND_USER -> $DEFEND_ROLE. Reads Cortex Agent traces after each turn."
  if [[ "$OWN_WAREHOUSE" == 0 ]]; then
    dedicated_warehouse
  fi
  emit "CREATE ROLE IF NOT EXISTS $DEFEND_ROLE COMMENT = 'Straiker Defend: reads Cortex Agent traces';"
  emit "GRANT USAGE ON WAREHOUSE $WAREHOUSE TO ROLE $DEFEND_ROLE;"
  for db in "${DATABASES[@]}"; do grant_database_monitor "$DEFEND_ROLE" "$db" 0; done
  emit "-- Without this, prompts, replies and tool data in the traces are redacted."
  emit "GRANT READ UNREDACTED AI OBSERVABILITY EVENTS TABLE ON ACCOUNT TO ROLE $DEFEND_ROLE;"
  service_user "$DEFEND_USER" "$DEFEND_ROLE" 'Straiker Defend trace monitoring' "$WAREHOUSE"
fi

if [[ "$ASCEND" == 1 ]]; then
  emit ""
  emit "-- Ascend: $ASCEND_USER -> $ASCEND_ROLE. The red-team identity: agents run their tools with"
  emit "-- this role's rights, so it holds what a real user of these agents holds. Never an admin role."
  emit "CREATE ROLE IF NOT EXISTS $ASCEND_ROLE COMMENT = 'Straiker Ascend: red-team identity for Cortex Agents';"
  if [[ ${#ASCEND_WHS[@]} -gt 0 ]]; then
    emit "-- The warehouses the agents' tools run their SQL on. Ascend's own REST calls need none."
  fi
  for w in ${ASCEND_WHS[@]+"${ASCEND_WHS[@]}"}; do
    if once "wh|$w"; then emit "GRANT USAGE ON WAREHOUSE $w TO ROLE $ASCEND_ROLE;"; fi
  done
  # USAGE on the database and schema of every object below.
  for obj in "${AGENTS[@]}" ${TABLES[@]+"${TABLES[@]}"} ${VIEWS[@]+"${VIEWS[@]}"} ${SEMVIEWS[@]+"${SEMVIEWS[@]}"} \
    ${SEARCHES[@]+"${SEARCHES[@]}"} ${PROCS[@]+"${PROCS[@]}"} ${FUNCS[@]+"${FUNCS[@]}"}; do
    base="${obj%%(*}"
    db="${base%%.*}"
    schema="${base%.*}"
    if once "db|$db"; then emit "GRANT USAGE ON DATABASE $db TO ROLE $ASCEND_ROLE;"; fi
    if once "schema|$schema"; then emit "GRANT USAGE ON SCHEMA $schema TO ROLE $ASCEND_ROLE;"; fi
  done
  emit "-- The agents under test."
  for a in "${AGENTS[@]}"; do if once "agent|$a"; then emit "GRANT USAGE ON AGENT $a TO ROLE $ASCEND_ROLE;"; fi; done
  if [[ ${#TABLES[@]} -gt 0 || ${#VIEWS[@]} -gt 0 || ${#SEMVIEWS[@]} -gt 0 || ${#SEARCHES[@]} -gt 0 || ${#PROCS[@]} -gt 0 || ${#FUNCS[@]} -gt 0 ]]; then
    emit "-- What their tools act on, with the caller's rights."
  fi
  for t in ${TABLES[@]+"${TABLES[@]}"}; do if once "table|$t"; then emit "GRANT SELECT ON TABLE $t TO ROLE $ASCEND_ROLE;"; fi; done
  for v in ${VIEWS[@]+"${VIEWS[@]}"}; do if once "view|$v"; then emit "GRANT SELECT ON VIEW $v TO ROLE $ASCEND_ROLE;"; fi; done
  for v in ${SEMVIEWS[@]+"${SEMVIEWS[@]}"}; do if once "sv|$v"; then emit "GRANT SELECT ON SEMANTIC VIEW $v TO ROLE $ASCEND_ROLE;"; fi; done
  for s in ${SEARCHES[@]+"${SEARCHES[@]}"}; do if once "search|$s"; then emit "GRANT USAGE ON CORTEX SEARCH SERVICE $s TO ROLE $ASCEND_ROLE;"; fi; done
  for p in ${PROCS[@]+"${PROCS[@]}"}; do if once "proc|$p"; then emit "GRANT USAGE ON PROCEDURE $p TO ROLE $ASCEND_ROLE;"; fi; done
  for f in ${FUNCS[@]+"${FUNCS[@]}"}; do if once "func|$f"; then emit "GRANT USAGE ON FUNCTION $f TO ROLE $ASCEND_ROLE;"; fi; done
  for r in ${INHERIT_ROLES[@]+"${INHERIT_ROLES[@]}"}; do
    if once "role|$r"; then emit "GRANT ROLE $r TO ROLE $ASCEND_ROLE;"; fi
  done
  service_user "$ASCEND_USER" "$ASCEND_ROLE" 'Straiker Ascend red-team identity'
fi

# ── Dry run: print the SQL and stop ──────────────────────────────────────────

if [[ "$DRY_RUN" == 1 ]]; then
  printf -- '-- DRY RUN: nothing was changed and no key was created. The SQL that would run, in order.\n'
  printf -- '-- Account: %s. It can also be pasted into a Snowsight worksheet (see the README for keys).\n' "$ACCOUNT"
  for i in "${!P_USER[@]}"; do
    printf -- '-- %s user %s: %s\n' "${P_LABEL[$i]}" "${P_USER[$i]}" "${P_NOTE[$i]}"
  done
  printf -- '-- Warehouse: %s\n' "$WH_NOTE"
  printf '\n%s' "$SQL"
  printf '\n-- Keys, set last: a key pair is generated in memory per user and only its public half is sent.\n'
  for i in "${!P_USER[@]}"; do
    [[ -n "${P_SLOT[$i]}" ]] || continue
    printf "ALTER USER %s SET %s = '<public key generated at apply time>';\n" "${P_USER[$i]}" "${P_SLOT[$i]}"
  done
  exit 0
fi

# ── Apply ────────────────────────────────────────────────────────────────────

if [[ ! -t 1 ]]; then
  log "warning: stdout is not a terminal; the private keys printed at the end will go wherever it points"
fi

log "Running the grants on account $ACCOUNT as $ADMIN_ROLE (connection '$CONNECTION')..."
sf_run "$SQL" || die "the grants failed (output above); nothing after the failing statement ran. Fix it and re-run: the script is idempotent"
log "  grants applied"

# Keys last, so a failed grant above does not leave a key Straiker was never given.
P_KEY=(); P_FP=()
KEY_SQL="USE ROLE $ADMIN_ROLE;"$'\n'
for i in "${!P_USER[@]}"; do
  P_KEY[i]=""; P_FP[i]=""
  [[ -n "${P_SLOT[$i]}" ]] || continue
  priv="$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)" || die "openssl could not generate a key"
  [[ "$priv" == "-----BEGIN PRIVATE KEY-----"* ]] || die "openssl did not produce an unencrypted PKCS#8 key"
  pub="$(printf '%s\n' "$priv" | openssl pkey -pubout 2>/dev/null | sed '/-----/d' | tr -d '\n')"
  [[ -n "$pub" ]] || die "openssl could not derive the public key"
  P_FP[i]="SHA256:$(printf '%s\n' "$priv" | openssl pkey -pubout -outform DER 2>/dev/null | openssl dgst -sha256 -binary | openssl enc -base64)"
  P_KEY[i]="$priv"
  KEY_SQL="${KEY_SQL}ALTER USER ${P_USER[$i]} SET ${P_SLOT[$i]} = '$pub';"$'\n'
done
priv=""

if [[ "$KEY_SQL" == *"ALTER USER"* ]]; then
  sf_run "$KEY_SQL" || die "setting the public keys failed (output above); the private keys were discarded. Re-run to try again"
  for i in "${!P_USER[@]}"; do
    [[ -n "${P_SLOT[$i]}" ]] || continue
    log "  ${P_USER[$i]}: new key in ${P_SLOT[$i]} (fingerprint ${P_FP[$i]})"
    if [[ -n "${P_RETIRE[$i]}" ]]; then
      log "    Once Straiker uses the new key, retire the old one: ALTER USER ${P_USER[$i]} UNSET ${P_RETIRE[$i]};"
    fi
  done
fi

# ── Output ───────────────────────────────────────────────────────────────────

print_user() {
  local i="$1" id
  id="$(printf '%s' "${P_LABEL[$i]}" | tr '[:upper:]' '[:lower:]')"
  printf '%s user  [%s_user]\n  %s\n' "${P_LABEL[$i]}" "$id" "${P_USER[$i]}"
  printf '%s private key  [%s_private_key]\n' "${P_LABEL[$i]}" "$id"
  if [[ -n "${P_KEY[$i]}" ]]; then
    printf '%s\n' "${P_KEY[$i]}"
  else
    printf '  (unchanged: the user keeps its key and Straiker keeps the one it holds; --rotate-keys mints a new one)\n'
  fi
}

{
  printf '\n==================== Paste into Straiker: Snowflake ====================\n'
  printf 'Account  [account]\n  %s\n' "$ACCOUNT"
  for i in "${!P_USER[@]}"; do
    case "${P_LABEL[$i]}" in
      Ascend) printf 'Allow Ascend to send test prompts to Cortex Agents  [ascend_enabled]\n  tick it\n' ;;
      Defend)
        printf 'Monitor Cortex Agent conversations with Straiker Defend  [defend_enabled]\n  tick it\n'
        if [[ "$OWN_WAREHOUSE" == 1 ]]; then
          printf 'Defend warehouse  [warehouse]\n  %s\n' "$WAREHOUSE"
        else
          printf 'Defend warehouse  [warehouse]\n  leave it empty: %s is the Defend user'"'"'s default warehouse\n' "$DEDICATED_WH"
        fi
        ;;
    esac
    print_user "$i"
  done
  printf '========================================================================\n'
  printf 'Private keys are shown once and were not saved anywhere. Paste each whole key, including\n'
  printf 'its BEGIN and END lines, into its own field.\n'
  printf 'Discover sees agents only in: %s. Re-run with any new database that holds agents.\n' "${DATABASES[*]}"
  if [[ "$DEFEND" == 1 && "$OWN_WAREHOUSE" == 0 ]]; then
    printf '%s suspends %s after %s credits in a month. Defend then stops reading traces until the\n' "$DEDICATED_RM" "$DEDICATED_WH" "$CREDIT_QUOTA"
    printf 'next month or until you raise it: ALTER RESOURCE MONITOR %s SET CREDIT_QUOTA = <n>;\n' "$DEDICATED_RM"
  fi
  if [[ "$ASCEND" == 1 ]]; then
    printf 'Ascend runs the agents for real: their tools act with its rights, and each probe is billed\n'
    printf 'to your Snowflake account.\n'
  fi
}
for i in "${!P_KEY[@]}"; do P_KEY[i]=""; done
