#!/usr/bin/env bash
# Straiker GCP onboarding script — Agent Platform + Gemini Enterprise.
#
# A single run provisions Straiker telemetry access for both:
#   - GCP Agent Platform (Vertex AI Reasoning Engine / Agent Engine)
#   - Gemini Enterprise (Discovery Engine assistant "StreamAssist" logs)
#
# It creates one service account, grants read-only IAM, optionally creates a
# shared GCS bucket + Cloud Logging sinks (--create-sink), enables Gemini
# Enterprise observability on every engine it finds (or only --engine-id ones),
# optionally configures Workload Identity Federation (WIF), and prints the
# values to enter in the Straiker UI. Single-project only.
#
# Both telemetry streams share one bucket: Cloud Logging writes each stream
# under its own log-name folder, so they never collide.
#   - Agent Platform: aiplatform.googleapis.com/reasoning_engine_stdout/...
#   - Gemini:         discoveryengine.googleapis.com/gemini_enterprise_user_activity/...
#
# Defaults: Gemini location is "global"; with no --engine-id the script lists
# and configures ALL engines in the location(s). Use --skip-gemini /
# --skip-agent-platform to provision only one platform.
#
# Inputs: use CLI flags (best for docs/CI/repeat runs) or run interactively on
# a TTY when flags are omitted. Use --non-interactive in pipelines so missing
# values error instead of prompting.
#
# Usage:
#   ./gcp-agent-platform-onboarding.sh [--project-id=...] [--telemetry-bucket=...] [--sa-name=...]
#              [--create-sink] [--bucket-name=...] [--bucket-location=...] [--sink-name=...]
#              [--gemini-location=...] [--engine-id=...] [--gemini-sink-name=...]
#              [--skip-gemini] [--skip-agent-platform]
#              [--enable-wif] [--straiker-aws-account-id=...]
#              [--gcp-project-number=...] [--wif-pool-id=...] [--wif-provider-id=...]
#              [--agent-platform-log-root=...] [--gemini-log-root=...]
#              [--wif-cred-config-out=PATH] [--force-provider-update]
#              [--dry-run] [--allow-sa-key] [--non-interactive]

set -euo pipefail

PROJECT_ID=""
SA_NAME="straiker-scanner"
TELEMETRY_BUCKET=""
NON_INTERACTIVE=""
ENABLE_WIF=""
WIF_FROM_CLI=0
STRAIKER_AWS_ACCOUNT_ID=""
GCP_PROJECT_NUMBER=""
WIF_POOL_ID=""
WIF_PROVIDER_ID="straiker-aws"
WIF_CRED_CONFIG_OUT=""
FORCE_PROVIDER_UPDATE=0
DRY_RUN=0
ALLOW_SA_KEY=0
KEY_FILE=""
CREATE_SINK=""
BUCKET_NAME=""
BUCKET_LOCATION="us-central1"
SINK_NAME="agent-engine-gcs-sink"

# Gemini Enterprise
SKIP_GEMINI=""
SKIP_AGENT_PLATFORM=""
GEMINI_LOCATION=""            # default resolved to "global" below
GEMINI_LOCATION_SET=0         # 1 when --gemini-location was passed (suppresses prompt)
GEMINI_SINK_NAME="gemini-enterprise-gcs-sink"
ENGINE_IDS=()                 # optional explicit scope; empty = discover all
# Empty unless the customer's sink writes logs somewhere non-standard. The defaults live in the
# scanner, so the script only has to carry an override. Both flags are a parent folder (e.g.
# team-a), not a Cloud Logging path — the scanner appends the log names for both platforms, so
# the value printed for the UI can be pasted into either field as-is.
AGENT_PLATFORM_PREFIX=""
GEMINI_PREFIX=""

usage() {
  cat <<USAGE
Usage:
  $0 [options]

  Core (flags or interactive on a TTY):
    --project-id=PROJECT_ID          GCP project ID (required)
    --telemetry-bucket=BUCKET        optional; roles/storage.objectViewer (strip gs://)
    --sa-name=NAME                   default: straiker-scanner

  Logging sink (optional; creates one shared bucket + per-platform sinks + writer IAM):
    --create-sink                    create GCS bucket + Cloud Logging sink(s) + grant writer IAM
    --bucket-name=NAME               default: agent-engine-logs-\${PROJECT_ID}
    --bucket-location=LOCATION       default: us-central1
    --sink-name=NAME                 Agent Platform sink name; default: agent-engine-gcs-sink
    --gemini-sink-name=NAME          Gemini sink name; default: gemini-enterprise-gcs-sink

  Gemini Enterprise (defaults make a plain run do the right thing):
    --gemini-location=LOC            default: global; accepts a space/comma list (e.g. "global us eu")
    --engine-id=ID                   advanced: repeatable; scopes to specific engines and skips the
                                       interactive all-engines confirm. When omitted ALL engines are configured.

  Platform scope (default: both):
    --skip-gemini                    do not touch Gemini Enterprise
    --skip-agent-platform            do not touch Agent Platform

  GCS log layout (only needed when your sink nests logs under a parent folder):
    --agent-platform-log-root=PATH   folder your sink nests Agent Platform logs under.
                                     Default: none. The scanner holds the full paths
                                     (aiplatform.googleapis.com/reasoning_engine_{stdout,stderr}).
    --gemini-log-root=PATH           folder your sink nests Gemini logs under.
                                     Default: none. Set independently — the two sinks can
                                     write to different folders.

  WIF (optional; same semantics as straiker-onboarding-prerequisites.md):
    --enable-wif                     WIF only: pool + AWS provider + SA bind + cred config (no JSON key)
    --straiker-aws-account-id=ID     12-digit Straiker AWS account (required with --enable-wif)
    --gcp-project-number=N           optional; resolved via gcloud if omitted
    --wif-pool-id=ID                 default: \${SA_NAME}-pool
    --wif-provider-id=ID             default: straiker-aws
    --wif-cred-config-out=PATH       default: a private mktemp dir (0700)
    --force-provider-update          rewrite an EXISTING provider's attribute mapping.
                                     Off by default: the default provider name is shared
                                     with the model-logs script, and rewriting a provider
                                     another integration uses breaks its auth.

  Other:
    --dry-run                        print every mutating command instead of running it.
                                     Nothing in GCP is touched; use this to review the
                                     change set with your platform team first.
    --allow-sa-key                   permit the long-lived service-account-key credential
                                     mode. Off by default — WIF is keyless and preferred.
    --non-interactive                require all inputs via flags; no prompts (for CI)

  Interactive (TTY): prompts for project, bucket, credential (w WIF default / k JSON key), and
  Gemini Enterprise (onboard? / location / confirm enabling observability on all engines). Passing
  the matching flag suppresses its prompt; --non-interactive disables all prompts.

  If --create-sink is not used, pass --telemetry-bucket for an existing bucket.
  For manual bucket/sink setup, see straiker-onboarding-prerequisites.md.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --project-id=*)                 PROJECT_ID="${arg#*=}" ;;
    --telemetry-bucket=*)           TELEMETRY_BUCKET="${arg#*=}" ;;
    --sa-name=*)                    SA_NAME="${arg#*=}" ;;
    --non-interactive)              NON_INTERACTIVE=1 ;;
    --enable-wif)                   ENABLE_WIF=1; WIF_FROM_CLI=1 ;;
    --straiker-aws-account-id=*)    STRAIKER_AWS_ACCOUNT_ID="${arg#*=}" ;;
    --gcp-project-number=*)         GCP_PROJECT_NUMBER="${arg#*=}" ;;
    --wif-pool-id=*)                WIF_POOL_ID="${arg#*=}" ;;
    --wif-provider-id=*)            WIF_PROVIDER_ID="${arg#*=}" ;;
    --wif-cred-config-out=*)        WIF_CRED_CONFIG_OUT="${arg#*=}" ;;
    --agent-platform-log-root=*)    AGENT_PLATFORM_PREFIX="${arg#*=}" ;;
    --gemini-log-root=*)            GEMINI_PREFIX="${arg#*=}" ;;
    --force-provider-update)        FORCE_PROVIDER_UPDATE=1 ;;
    --dry-run)                      DRY_RUN=1 ;;
    --allow-sa-key)                 ALLOW_SA_KEY=1 ;;
    --create-sink)                  CREATE_SINK=1 ;;
    --bucket-name=*)                BUCKET_NAME="${arg#*=}" ;;
    --bucket-location=*)            BUCKET_LOCATION="${arg#*=}" ;;
    --sink-name=*)                  SINK_NAME="${arg#*=}" ;;
    --gemini-location=*)            GEMINI_LOCATION="${arg#*=}"; GEMINI_LOCATION_SET=1 ;;
    --gemini-sink-name=*)           GEMINI_SINK_NAME="${arg#*=}" ;;
    --engine-id=*)                  ENGINE_IDS+=("${arg#*=}") ;;
    --skip-gemini)                  SKIP_GEMINI=1 ;;
    --skip-agent-platform)          SKIP_AGENT_PLATFORM=1 ;;
    -h|--help)                      usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage; exit 2 ;;
  esac
done

interactive() {
  [[ -z "${NON_INTERACTIVE}" && -t 0 ]]
}

die() { echo "Error: $*" >&2; exit 2; }

# run wraps every mutating call so --dry-run can print it instead of executing. A
# customer's platform team needs to see the change set before it touches their
# project; there is no preflight or rollback in a POC script, so "show me first" is
# the only review mechanism available.
run() {
  if [[ "${DRY_RUN}" == 1 ]]; then
    printf '  DRY-RUN:'; printf ' %q' "$@"; printf '\n'
    return 0
  fi
  "$@"
}

# Same as run, but discards the command's own stdout. The IAM calls print the whole
# resulting policy, which is noise. Do NOT write `run gcloud ... >/dev/null` instead:
# that redirect applies to run itself and swallows the DRY-RUN line, so the mutation
# silently disappears from the plan the operator is reviewing.
run_quiet() {
  if [[ "${DRY_RUN}" == 1 ]]; then
    printf '  DRY-RUN:'; printf ' %q' "$@"; printf '\n'
    return 0
  fi
  "$@" >/dev/null
}

# Credential artefacts go in a private, unpredictable directory. A fixed path under
# /tmp is world-readable and we cannot know where the customer runs this — a shared
# bastion, a CI workspace that gets archived, or a git repo. mktemp -d + 0700 keeps
# the file readable only by the operator, and the path is printed so they can find it.
secure_outdir() {
  local base d
  # Honour TMPDIR so this lands in the per-user private dir on macOS rather than a
  # shared /tmp. Strip any trailing slash first: macOS sets TMPDIR with one, which
  # otherwise yields a "…/T//straiker-…" double slash in a path we print to the
  # operator and ask them to rm -f.
  base="${TMPDIR:-/tmp}"
  base="${base%/}"
  d="$(mktemp -d "${base}/straiker-onboarding-XXXXXX")" || \
    die "could not create a private output directory"
  chmod 700 "${d}"
  printf '%s' "${d}"
}

# Trim whitespace and surrounding slashes so a path can be pasted from a bucket listing.
gcs_path() {
  local v="${1//[[:space:]]/}"
  v="${v#/}"; v="${v%/}"
  printf '%s' "${v}"
}


# Discovery Engine host for a location: global uses the bare host, multi/single
# regions use a "<loc>-" prefix (e.g. us-discoveryengine.googleapis.com).
gemini_host() {
  local loc="$1"
  if [[ "$loc" == "global" ]]; then
    echo "discoveryengine.googleapis.com"
  else
    echo "${loc}-discoveryengine.googleapis.com"
  fi
}

[[ -n "${SKIP_GEMINI}" && -n "${SKIP_AGENT_PLATFORM}" ]] && \
  die "--skip-gemini and --skip-agent-platform together leave nothing to do."

GEMINI_LOCATION="${GEMINI_LOCATION:-global}"


if interactive && [[ -z "${PROJECT_ID}" ]]; then
  read -r -p "GCP project ID: " PROJECT_ID
fi
[[ -n "${PROJECT_ID}" ]] || die "--project-id is required (or run interactively on a TTY)."
# Validate the project ID before it reaches an API call or gets pasted into a service
# account email. GCP rule: 6-30 chars, lowercase letter first, then lowercase letters,
# digits or hyphens, no trailing hyphen. Without this a typo produced a nonsense SA
# email ("straiker-scanner@Bad Project!.iam...") and failed later in a confusing place.
[[ "${PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || \
  die "invalid GCP project ID '${PROJECT_ID}' (expected 6-30 chars: lowercase letter first, then lowercase letters, digits or hyphens)."

if [[ -z "${CREATE_SINK}" ]] && interactive && [[ -z "${TELEMETRY_BUCKET}" ]]; then
  cat <<'SINK_PROMPT'
GCS telemetry bucket setup:
  c  Create new bucket + logging sink(s) (recommended for new setups)
  e  Enter existing bucket name
  s  Skip (configure later)
SINK_PROMPT
  read -r -p "Choice [c]: " _sink_choice
  case "${_sink_choice}" in
    c|C|"")
      CREATE_SINK=1
      ;;
    e|E)
      read -r -p "Existing GCS bucket name (without gs://): " TELEMETRY_BUCKET
      # Asked only here: a bucket this script creates has the standard layout already.
      cat <<'PREFIX_PROMPT'

  GCS log paths. Press Enter to accept the standard Cloud Logging layout; override
  only if your sink writes these logs somewhere else.
PREFIX_PROMPT
      if [[ -z "${SKIP_AGENT_PLATFORM}" ]]; then
        read -r -p "  Agent Platform folder, if any [none]: " _apr
        [[ -n "${_apr}" ]] && AGENT_PLATFORM_PREFIX="${_apr}"
      fi
      if [[ -z "${SKIP_GEMINI}" ]]; then
        read -r -p "  Gemini folder, if any [none]: " _gmr
        [[ -n "${_gmr}" ]] && GEMINI_PREFIX="${_gmr}"
      fi
      ;;
    s|S)
      ;;
    *)
      die "Invalid choice (use c, e, or s)."
      ;;
  esac
fi

# Normalise after every input path — flags and prompts both land above this point.
AGENT_PLATFORM_PREFIX="$(gcs_path "${AGENT_PLATFORM_PREFIX}")"
GEMINI_PREFIX="$(gcs_path "${GEMINI_PREFIX}")"

if [[ "${CREATE_SINK}" == 1 ]] && interactive && [[ -z "${BUCKET_NAME}" ]]; then
  _default_bucket="agent-engine-logs-${PROJECT_ID}"
  read -r -p "Bucket name [${_default_bucket}]: " _bname
  BUCKET_NAME="${_bname:-${_default_bucket}}"
  read -r -p "Bucket location [${BUCKET_LOCATION}]: " _bloc
  [[ -n "${_bloc}" ]] && BUCKET_LOCATION="${_bloc}"
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "Error: gcloud CLI not found in PATH" >&2
  exit 1
fi

# Credential mode: --enable-wif from CLI, or interactive w / k.
if interactive && [[ "${WIF_FROM_CLI}" == 0 ]]; then
  cat <<'PROMPT'
Straiker UI credential (pick one):
  w  WIF only (keyless) — binds roles/iam.workloadIdentityUser on the service account;
       needs iam.serviceAccounts.setIamPolicy (e.g. roles/iam.serviceAccountAdmin)
  k  Service account JSON key — LONG-LIVED credential, requires --allow-sa-key
PROMPT
  read -r -p "Choice [w]: " _cred_choice
  case "${_cred_choice}" in
    w|W|"")
      ENABLE_WIF=1
      ;;
    k|K)
      [[ "${ALLOW_SA_KEY}" == 1 ]] || die "service-account-key mode needs --allow-sa-key (WIF is keyless and preferred)."
      ENABLE_WIF=0
      ;;
    *)
      die "Invalid choice (use w or k)."
      ;;
  esac
elif [[ "${WIF_FROM_CLI}" == 0 ]]; then
  # No --enable-wif on a non-TTY run. Key mode is opt-in, so require the flag rather
  # than silently minting a long-lived credential.
  [[ "${ALLOW_SA_KEY}" == 1 ]] || die "pass --enable-wif (recommended) or --allow-sa-key to use a service-account key."
  ENABLE_WIF=0
fi

if [[ "${ENABLE_WIF}" == 1 ]]; then
  if interactive && [[ -z "${STRAIKER_AWS_ACCOUNT_ID}" ]]; then
    read -r -p "Straiker AWS account ID (12 digits, from your Straiker contact): " STRAIKER_AWS_ACCOUNT_ID
  fi
  [[ -n "${STRAIKER_AWS_ACCOUNT_ID}" ]] || die "WIF requires --straiker-aws-account-id= (or enter it when prompted)."
  [[ "${STRAIKER_AWS_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]] || die "Straiker AWS account ID must be exactly 12 digits."
fi

HOME_PROJECT="$PROJECT_ID"
BIND_TARGET_FLAG="projects"
BIND_TARGET_ID="$PROJECT_ID"
SA_EMAIL="${SA_NAME}@${HOME_PROJECT}.iam.gserviceaccount.com"

if [[ "${ENABLE_WIF}" == 1 ]]; then
  [[ -n "${WIF_POOL_ID}" ]] || WIF_POOL_ID="${SA_NAME}-pool"
  # Resolve the output path without calling secure_outdir under --dry-run: it creates
  # the directory as a side effect, and a dry run that leaves 0700 dirs behind in TMPDIR
  # contradicts "nothing is touched". The placeholder is only ever printed.
  if [[ -z "${WIF_CRED_CONFIG_OUT}" ]]; then
    if [[ "${DRY_RUN}" == 1 ]]; then
      WIF_CRED_CONFIG_OUT="<private-mktemp-dir>/straiker-wif-cred-${HOME_PROJECT}.json"
    else
      WIF_CRED_CONFIG_OUT="$(secure_outdir)/straiker-wif-cred-${HOME_PROJECT}.json"
    fi
  fi
  if interactive && [[ -z "${GCP_PROJECT_NUMBER}" ]]; then
    read -r -p "GCP project number (Enter to resolve with gcloud): " _pn
    GCP_PROJECT_NUMBER="${_pn}"
  fi
  if [[ -z "${GCP_PROJECT_NUMBER}" ]]; then
    GCP_PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
  fi
  [[ -n "${GCP_PROJECT_NUMBER}" ]] || die "Could not resolve GCP project number."
  if interactive; then
    read -r -p "WIF pool ID [${WIF_POOL_ID}]: " _pool
    [[ -n "${_pool}" ]] && WIF_POOL_ID="${_pool}"
    read -r -p "WIF AWS provider ID [${WIF_PROVIDER_ID}]: " _prov
    [[ -n "${_prov}" ]] && WIF_PROVIDER_ID="${_prov}"
    read -r -p "WIF credential config output path [${WIF_CRED_CONFIG_OUT}]: " _out
    [[ -n "${_out}" ]] && WIF_CRED_CONFIG_OUT="${_out}"
  fi
fi

# Gemini Enterprise prompts (the all-engines confirmation happens later in [2],
# after discovery). If --skip-agent-platform is set, Gemini is implied — no ask.
if interactive && [[ -z "${SKIP_GEMINI}" && -z "${SKIP_AGENT_PLATFORM}" ]]; then
  read -r -p "Onboard Gemini Enterprise? [Y/n]: " _gem_choice
  case "${_gem_choice}" in
    n|N) SKIP_GEMINI=1 ;;
  esac
fi
if interactive && [[ -z "${SKIP_GEMINI}" && "${GEMINI_LOCATION_SET}" -eq 0 ]]; then
  read -r -p "Gemini location [${GEMINI_LOCATION}]: " _gem_loc
  [[ -n "${_gem_loc}" ]] && GEMINI_LOCATION="${_gem_loc}"
fi

echo "── Straiker scanner onboarding ──"
if [[ "${DRY_RUN}" == 1 ]]; then
  echo "  Mode:          DRY RUN — no GCP resource will be created or modified"
fi
echo "  Project:       ${HOME_PROJECT}"
echo "  Bind target:   ${BIND_TARGET_FLAG}/${BIND_TARGET_ID}"
echo "  SA email:      ${SA_EMAIL}"
echo -n "  Platforms:     "
if [[ -z "${SKIP_AGENT_PLATFORM}" && -z "${SKIP_GEMINI}" ]]; then
  echo "Agent Platform + Gemini Enterprise"
elif [[ -z "${SKIP_AGENT_PLATFORM}" ]]; then
  echo "Agent Platform only"
else
  echo "Gemini Enterprise only"
fi
# Each platform's folder is named separately: the two are independent, and the Gemini one
# was omitted here entirely, so a Gemini-only run showed no prefix at all.
if [[ -z "${SKIP_AGENT_PLATFORM}" ]]; then
  [[ -n "${AGENT_PLATFORM_PREFIX}" ]] && echo "  AP folder:     ${AGENT_PLATFORM_PREFIX}"
fi
if [[ -z "${SKIP_GEMINI}" ]]; then
  [[ -n "${GEMINI_PREFIX}" ]] && echo "  Gemini folder: ${GEMINI_PREFIX}"
  echo "  Gemini loc:    ${GEMINI_LOCATION}"
fi
if [[ "${ENABLE_WIF}" == 1 ]]; then
  echo "  Credentials:   WIF only (${WIF_POOL_ID} / ${WIF_PROVIDER_ID})"
else
  echo "  Credentials:   service account JSON key"
fi
echo ""

# ── [1] Enable APIs ─────────────────────────────────────────────────────────
APIS=(
  storage.googleapis.com
  cloudresourcemanager.googleapis.com
  iam.googleapis.com
  logging.googleapis.com
)
if [[ -z "${SKIP_AGENT_PLATFORM}" ]]; then
  APIS+=(aiplatform.googleapis.com cloudtrace.googleapis.com)
fi
if [[ -z "${SKIP_GEMINI}" ]]; then
  APIS+=(discoveryengine.googleapis.com)
fi
if [[ "${ENABLE_WIF}" == 1 ]]; then
  APIS+=(sts.googleapis.com iamcredentials.googleapis.com)
fi

echo "[1] Enabling required APIs in ${HOME_PROJECT}..."
run gcloud services enable "${APIS[@]}" --project="${HOME_PROJECT}"

# ── [2] Gemini Enterprise observability (per-engine; no project-wide toggle) ─
# observabilityConfig is set per app/engine. We discover engines (or use the
# explicit --engine-id scope) and PATCH each one. sensitiveLoggingEnabled is
# required so Straiker receives prompt/response content (otherwise sanitized).
GEMINI_PRESENT=0
PATCHED_ENGINES=()   # "loc|engine_id" entries that were successfully PATCHed
GEMINI_TOKEN=""

if [[ -z "${SKIP_GEMINI}" ]]; then
  echo "[2] Enabling Gemini Enterprise observability..."
  if ! command -v curl >/dev/null 2>&1; then
    echo "  (warning: curl not found — skipping Gemini observability; install curl or use --skip-gemini)" >&2
  else
    GEMINI_TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
    if [[ -z "${GEMINI_TOKEN}" ]]; then
      echo "  (warning: could not obtain access token via gcloud — skipping Gemini observability)" >&2
    else
      read -r -a _LOCS <<< "${GEMINI_LOCATION//,/ }"
      _TMP_RESP="$(mktemp 2>/dev/null || echo /tmp/straiker-gem-$$.json)"

      # Pass 1 — collect all targets ("loc|engine_id") before touching anything.
      TARGETS=()
      for _loc in "${_LOCS[@]}"; do
        [[ -n "${_loc}" ]] || continue
        _host="$(gemini_host "${_loc}")"
        _parent="projects/${PROJECT_ID}/locations/${_loc}/collections/default_collection"

        if [[ ${#ENGINE_IDS[@]} -gt 0 ]]; then
          for _eid in "${ENGINE_IDS[@]}"; do
            [[ -n "${_eid}" ]] && TARGETS+=("${_loc}|${_eid}")
          done
        else
          _list_url="https://${_host}/v1alpha/${_parent}/engines?pageSize=100"
          _list_resp="$(curl -sS -H "Authorization: Bearer ${GEMINI_TOKEN}" \
            -H "X-Goog-User-Project: ${PROJECT_ID}" "${_list_url}" 2>/dev/null || true)"
          _loc_count=0
          if command -v jq >/dev/null 2>&1; then
            while IFS= read -r _eid; do
              [[ -n "${_eid}" ]] && { TARGETS+=("${_loc}|${_eid}"); _loc_count=$((_loc_count+1)); }
            done < <(printf '%s' "${_list_resp}" | jq -r '.engines[]?.name | sub(".*/engines/";"")' 2>/dev/null || true)
          else
            while IFS= read -r _eid; do
              [[ -n "${_eid}" ]] && { TARGETS+=("${_loc}|${_eid}"); _loc_count=$((_loc_count+1)); }
            done < <(printf '%s' "${_list_resp}" \
              | grep -oE 'projects/[^"]*/engines/[^"]+' \
              | sed -E 's#.*/engines/##' | sort -u)
          fi
          [[ "${_loc_count}" -eq 0 ]] && \
            echo "  ${_loc}: no engines found (or insufficient permission to list)"
        fi
      done

      # Confirmation gate — interactive runs without --engine-id confirm once
      # before enabling on all engines (this also enables sensitive logging).
      _do_patch=1
      if [[ ${#TARGETS[@]} -eq 0 ]]; then
        _do_patch=0
      elif interactive && [[ ${#ENGINE_IDS[@]} -eq 0 ]]; then
        echo "  Found ${#TARGETS[@]} Gemini Enterprise engine(s):"
        for _entry in "${TARGETS[@]}"; do
          echo "    - ${_entry%%|*}/${_entry#*|}"
        done
        read -r -p "  Enable observability on all ${#TARGETS[@]} engine(s)? This turns on sensitiveLoggingEnabled (logs full prompts/responses, may include PII) [Y/n]: " _gem_all
        case "${_gem_all}" in
          n|N)
            _do_patch=0
            echo "  Skipping Gemini Enterprise (declined)."
            ;;
        esac
      fi

      # Pass 2 — PATCH the confirmed targets.
      if [[ "${_do_patch}" -eq 1 ]]; then
        for _entry in "${TARGETS[@]}"; do
          _loc="${_entry%%|*}"; _eid="${_entry#*|}"
          _host="$(gemini_host "${_loc}")"
          _parent="projects/${PROJECT_ID}/locations/${_loc}/collections/default_collection"
          _patch_url="https://${_host}/v1alpha/${_parent}/engines/${_eid}?updateMask=observabilityConfig"
          if [[ "${DRY_RUN}" == 1 ]]; then
            # A PATCH is a mutation like any gcloud call; --dry-run must not send it.
            echo "  DRY-RUN: PATCH ${_patch_url}"
            echo "           {\"observabilityConfig\":{\"observabilityEnabled\":true,\"sensitiveLoggingEnabled\":true}}"
            GEMINI_PRESENT=1
            continue
          fi
          GEMINI_PRESENT=1
          _code="$(curl -sS -o "${_TMP_RESP}" -w '%{http_code}' -X PATCH \
            -H "Authorization: Bearer ${GEMINI_TOKEN}" \
            -H "Content-Type: application/json" \
            -H "X-Goog-User-Project: ${PROJECT_ID}" \
            "${_patch_url}" \
            -d '{"observabilityConfig":{"observabilityEnabled":true,"sensitiveLoggingEnabled":true}}' \
            2>/dev/null || echo "000")"
          if [[ "${_code}" == "200" ]]; then
            echo "  ${_loc}/${_eid}: observability enabled"
            PATCHED_ENGINES+=("${_loc}|${_eid}")
          else
            echo "  ${_loc}/${_eid}: PATCH failed (HTTP ${_code})" >&2
            [[ -s "${_TMP_RESP}" ]] && sed 's/^/    /' "${_TMP_RESP}" >&2 || true
            echo "    (needs the Gemini Enterprise Admin role / discoveryengine.engines.update)" >&2
          fi
        done
      fi

      rm -f "${_TMP_RESP}" 2>/dev/null || true
      if [[ "${GEMINI_PRESENT}" -eq 0 ]]; then
        echo "  No Gemini Enterprise engines configured; omitting Gemini from output."
      fi
    fi
  fi
else
  echo "[2] Skipping Gemini Enterprise (not selected)."
fi

# ── [3] Shared bucket + per-platform logging sinks ──────────────────────────
ensure_sink() {
  local sink_name="$1" filter="$2" writer
  echo "  sink ${sink_name}..."
  if gcloud logging sinks describe "${sink_name}" --project="${HOME_PROJECT}" >/dev/null 2>&1; then
    echo "    (exists, skipping create)"
  else
    # Idempotency here is by NAME, but Cloud Logging happily runs two sinks with the
    # same filter and destination — which double-writes every object and doubles the
    # egress bill. A customer who created the sink by hand, or with an older default
    # name, has one this script cannot see, so check the filter before creating.
    # Verified against nonprod, where the live sink is "gemini-enterprise-sink" while
    # this script defaults to "gemini-enterprise-gcs-sink".
    # Compare locally rather than with `gcloud ... --filter=filter:(...)`: that
    # server-side expression silently matches nothing on the sink's own filter field,
    # so it reported "no duplicate" every time and created the second sink anyway.
    local existing="" _n _d _f
    while IFS=$'\t' read -r _n _d _f; do
      [[ "${_d}" == "storage.googleapis.com/${BUCKET_NAME}" ]] || continue
      [[ "${_f}" == "${filter}" ]] || continue
      existing="${_n}"
      break
    done < <(gcloud logging sinks list --project="${HOME_PROJECT}" \
      --format='value[separator="\t"](name,destination,filter)' 2>/dev/null || true)
    if [[ -n "${existing}" ]]; then
      echo "    a sink with this filter and destination already exists: ${existing}"
      echo "    reusing it instead of creating '${sink_name}' — two sinks with the same"
      echo "    filter would export every log object twice."
      echo "    (pass --sink-name/--gemini-sink-name='${existing}' to manage it by name.)"
      sink_name="${existing}"
    else
      run gcloud logging sinks create "${sink_name}" \
        "storage.googleapis.com/${BUCKET_NAME}" \
        --project="${HOME_PROJECT}" \
        --log-filter="${filter}"
    fi
  fi
  # A sink created under --dry-run does not exist, so it has no writerIdentity to
  # bind. Print the intent instead of failing on an empty --member.
  writer="$(gcloud logging sinks describe "${sink_name}" \
    --project="${HOME_PROJECT}" \
    --format='value(writerIdentity)' 2>/dev/null || true)"
  if [[ -z "${writer}" ]]; then
    if [[ "${DRY_RUN}" == 1 ]]; then
      echo "    DRY-RUN: grant roles/storage.objectCreator to the new sink's writerIdentity on gs://${BUCKET_NAME}"
    else
      echo "    (warning: could not resolve sink writerIdentity — grant roles/storage.objectCreator manually)" >&2
    fi
    return 0
  fi
  run_quiet gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
    --member="${writer}" \
    --role="roles/storage.objectCreator" \
    --quiet || echo "    (warning: sink writer IAM binding failed)" >&2
}

if [[ "${CREATE_SINK}" == 1 ]]; then
  [[ -n "${BUCKET_NAME}" ]] || BUCKET_NAME="agent-engine-logs-${HOME_PROJECT}"

  echo "[3] Creating shared GCS bucket + logging sinks..."
  echo "  bucket gs://${BUCKET_NAME} in ${BUCKET_LOCATION}..."
  if gcloud storage buckets describe "gs://${BUCKET_NAME}" >/dev/null 2>&1; then
    echo "    (bucket already exists, skipping create)"
  else
    run gcloud storage buckets create "gs://${BUCKET_NAME}" \
      --project="${HOME_PROJECT}" \
      --location="${BUCKET_LOCATION}" \
      --uniform-bucket-level-access
  fi

  if [[ -z "${SKIP_AGENT_PLATFORM}" ]]; then
    ensure_sink "${SINK_NAME}" 'resource.type="aiplatform.googleapis.com/ReasoningEngine"'
  fi
  if [[ -z "${SKIP_GEMINI}" && "${GEMINI_PRESENT}" -eq 1 ]]; then
    # logName is a fixed identifier, not a path: a custom folder must NOT appear here.
    ensure_sink "${GEMINI_SINK_NAME}" \
      "logName=\"projects/${PROJECT_ID}/logs/discoveryengine.googleapis.com%2Fgemini_enterprise_user_activity\""
  fi

  # Both sinks write here; objectViewer step below grants the scanner read.
  TELEMETRY_BUCKET="${BUCKET_NAME}"
else
  echo "[3] Skipping bucket/sink creation (no --create-sink)."
fi

# ── [4] Service account ─────────────────────────────────────────────────────
echo "[4] Creating service account ${SA_EMAIL}..."
if gcloud iam service-accounts describe "$SA_EMAIL" --project="${HOME_PROJECT}" >/dev/null 2>&1; then
  echo "  (already exists, skipping create)"
else
  run gcloud iam service-accounts create "$SA_NAME" \
    --display-name="Straiker Scanner" \
    --description="Read-only access for Straiker agent telemetry scanning." \
    --project="${HOME_PROJECT}"
  if [[ "${DRY_RUN}" != 1 ]]; then
    echo "  waiting 8s for SA propagation..."
    sleep 8
  fi
fi

# ── [5] Project IAM (Agent Platform discovery only) ─────────────────────────
# Gemini Enterprise reads only from GCS, so it needs no project-level roles.
if [[ -z "${SKIP_AGENT_PLATFORM}" ]]; then
  echo "[5] Binding IAM roles at ${BIND_TARGET_FLAG}/${BIND_TARGET_ID}..."
  ROLES=("roles/aiplatform.viewer" "roles/cloudtrace.user")
  for ROLE in "${ROLES[@]}"; do
    echo "  binding ${ROLE}"
    run_quiet gcloud "$BIND_TARGET_FLAG" add-iam-policy-binding "$BIND_TARGET_ID" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="$ROLE" \
      --condition=None \
      --quiet
  done
else
  echo "[5] Skipping project IAM (Gemini Enterprise needs bucket read only)."
fi

# ── [6] Bucket read access (shared by both platforms) ───────────────────────
if [[ -n "$TELEMETRY_BUCKET" ]]; then
  BUCKET_REF="$TELEMETRY_BUCKET"
  BUCKET_REF="${BUCKET_REF#gs://}"
  BUCKET_REF="${BUCKET_REF%%/*}"
  echo "[6] Binding roles/storage.objectViewer on gs://${BUCKET_REF}..."
  run_quiet gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_REF}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.objectViewer" \
    --quiet || {
      echo "  (warning: bucket IAM binding failed — grant storage.objectViewer manually on gs://${BUCKET_REF})" >&2
    }
else
  echo "[6] Skipping telemetry bucket IAM (pass --telemetry-bucket=BUCKET or --create-sink to bind objectViewer)."
fi

# ── [7] Workload Identity Federation (optional) ─────────────────────────────
if [[ "${ENABLE_WIF}" == 1 ]]; then
  echo "[7] Configuring Workload Identity Federation..."
  if gcloud iam workload-identity-pools describe "${WIF_POOL_ID}" \
    --location=global --project="${HOME_PROJECT}" >/dev/null 2>&1; then
    echo "  pool ${WIF_POOL_ID} already exists"
  else
    run gcloud iam workload-identity-pools create "${WIF_POOL_ID}" \
      --location=global \
      --display-name="Straiker Scanner" \
      --project="${HOME_PROJECT}"
  fi
  # google.subject must be ≤127 bytes. assertion.arn often exceeds that (EKS Pod Identity,
  # long IAM role paths). Map a short subject; keep full ARN on attribute.aws_arn for auditing.
  _WIF_ATTR_MAP='google.subject=assertion.account,attribute.aws_account=assertion.account,attribute.aws_arn=assertion.arn'
  _WIF_ATTR_COND="assertion.arn.contains(':assumed-role/')"
  WIF_PROVIDER_EXISTED=0
  if gcloud iam workload-identity-pools providers describe "${WIF_PROVIDER_ID}" \
    --location=global \
    --workload-identity-pool="${WIF_POOL_ID}" \
    --project="${HOME_PROJECT}" >/dev/null 2>&1; then
    echo "  provider ${WIF_PROVIDER_ID} already exists"
    WIF_PROVIDER_EXISTED=1
  else
    run gcloud iam workload-identity-pools providers create-aws "${WIF_PROVIDER_ID}" \
      --location=global \
      --workload-identity-pool="${WIF_POOL_ID}" \
      --account-id="${STRAIKER_AWS_ACCOUNT_ID}" \
      --attribute-mapping="${_WIF_ATTR_MAP}" \
      --attribute-condition="${_WIF_ATTR_COND}" \
      --project="${HOME_PROJECT}"
  fi
  if [[ "${WIF_PROVIDER_EXISTED}" -eq 1 ]]; then
    # A pre-existing provider is REUSED AS-IS unless it actually differs, and a
    # differing one is never rewritten silently. WIF_PROVIDER_ID defaults to a name
    # shared with the model-logs script, so an unconditional update-aws here would
    # rewrite the attribute mapping and condition of a provider that another
    # integration is already authenticating against — breaking it, from a script the
    # operator believes is only onboarding agent platform. Any federated identity
    # whose ARN lacks ':assumed-role/' would stop authenticating immediately.
    _cur_map="$(gcloud iam workload-identity-pools providers describe "${WIF_PROVIDER_ID}" \
      --location=global --workload-identity-pool="${WIF_POOL_ID}" --project="${HOME_PROJECT}" \
      --format='value[delimiter=","](attributeMapping)' 2>/dev/null || true)"
    _cur_cond="$(gcloud iam workload-identity-pools providers describe "${WIF_PROVIDER_ID}" \
      --location=global --workload-identity-pool="${WIF_POOL_ID}" --project="${HOME_PROJECT}" \
      --format='value(attributeCondition)' 2>/dev/null || true)"

    # Compare the mapping as an order-insensitive SET of key=value pairs. A substring
    # test on 'google.subject' would not do: a provider mapping
    # google.subject=assertion.arn is a DIFFERENT mapping that still contains the key,
    # and reusing it silently makes the scanner authenticate under the wrong subject.
    _norm() { tr ',' '\n' <<<"${1}" | sed '/^$/d' | sort | paste -sd, -; }
    _cur_norm="$(_norm "${_cur_map}")"
    _want_norm="$(_norm "${_WIF_ATTR_MAP}")"

    if [[ "${_cur_norm}" == "${_want_norm}" && "${_cur_cond}" == "${_WIF_ATTR_COND}" ]]; then
      echo "  provider mapping and condition already match — reusing as-is (no update)"
    elif [[ "${FORCE_PROVIDER_UPDATE}" == 1 ]]; then
      echo "  !! overwriting attribute mapping/condition on existing provider (--force-provider-update)"
      echo "     current mapping  : ${_cur_map:-<none>}"
      echo "     current condition: ${_cur_cond:-<none>}"
      echo "     new mapping      : ${_WIF_ATTR_MAP}"
      echo "     new condition    : ${_WIF_ATTR_COND}"
      run gcloud iam workload-identity-pools providers update-aws "${WIF_PROVIDER_ID}" \
        --location=global \
        --workload-identity-pool="${WIF_POOL_ID}" \
        --attribute-mapping="${_WIF_ATTR_MAP}" \
        --attribute-condition="${_WIF_ATTR_COND}" \
        --project="${HOME_PROJECT}"
    else
      echo ""
      echo "  REFUSING to modify existing provider '${WIF_PROVIDER_ID}'."
      echo "    current mapping  : ${_cur_map:-<none>}"
      echo "    current condition: ${_cur_cond:-<none>}"
      echo "    this script wants: ${_WIF_ATTR_MAP}"
      echo "                      ${_WIF_ATTR_COND}"
      echo ""
      echo "  That provider may already be in use by another integration; rewriting it"
      echo "  can break its authentication. Choose one:"
      echo "    • re-run with --wif-provider-id=<new-name>  (recommended: a separate provider)"
      echo "    • re-run with --force-provider-update       (only if you own this provider)"
      echo ""
      echo "  Nothing was changed on that provider. Earlier steps (APIs, service account,"
      echo "  role bindings, bucket, pool) are already applied and are safe to re-run —"
      echo "  this script is idempotent, so just re-run it with one of the flags above."
      die "existing WIF provider left unchanged"
    fi
  fi
  echo "  binding workloadIdentityUser on ${SA_EMAIL}"
  if ! run_quiet gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${GCP_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/attribute.aws_account/${STRAIKER_AWS_ACCOUNT_ID}" \
    --project="${HOME_PROJECT}" \
    --quiet; then
    cat >&2 <<'ERR'
Error: gcloud iam service-accounts add-iam-policy-binding failed (often PERMISSION_DENIED:
iam.serviceAccounts.setIamPolicy).

That permission applies to the service account resource itself — not the same as
project-level roles/resourcemanager.projects.setIamPolicy. Typical fixes:

  • Ask a project Owner to grant you roles/iam.serviceAccountAdmin (or run this
    binding for you), or
  • Use credential mode "k" (--allow-sa-key) if you can create keys but cannot
    set IAM policy on service accounts.

See also: straiker-onboarding-prerequisites.md (What You Need / IAM permissions).
ERR
    exit 1
  fi
  echo "  writing WIF credential config to ${WIF_CRED_CONFIG_OUT}"
  run gcloud iam workload-identity-pools create-cred-config \
    "projects/${GCP_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/providers/${WIF_PROVIDER_ID}" \
    --service-account="${SA_EMAIL}" \
    --aws \
    --output-file="${WIF_CRED_CONFIG_OUT}"
  # The cred config identifies the SA to impersonate: restrict it rather than
  # leaving whatever umask the operator happens to run with.
  chmod 600 "${WIF_CRED_CONFIG_OUT}" 2>/dev/null || true
else
  echo "[7] Skipping Workload Identity Federation (JSON key mode)."
fi

# ── [8] Service account JSON key (when not WIF) ─────────────────────────────
# KEY_FILE is resolved here, not up front: secure_outdir() makes a directory as a
# side effect, so calling it in WIF mode would litter an empty 0700 dir every run.
if [[ "${ENABLE_WIF}" == 1 ]]; then
  echo "[8] Skipping SA JSON key (WIF only)."
elif [[ "${DRY_RUN}" == 1 ]]; then
  # Do not call secure_outdir here: it creates a directory as a side effect, and a
  # dry run that leaves 0700 dirs scattered in TMPDIR is not the "touches nothing"
  # contract --dry-run advertises.
  echo "[8] Creating JSON key in a private mktemp dir..."
  run gcloud iam service-accounts keys create "<private-mktemp-dir>/straiker-key-${HOME_PROJECT}.json" \
    --iam-account="$SA_EMAIL" \
    --project="${HOME_PROJECT}"
else
  KEY_FILE="$(secure_outdir)/straiker-key-${HOME_PROJECT}.json"
  echo "[8] Creating JSON key at ${KEY_FILE}..."
  run gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account="$SA_EMAIL" \
    --project="${HOME_PROJECT}"
  chmod 600 "${KEY_FILE}" 2>/dev/null || true
fi

# ── [9] Verification (advisory; non-fatal) ──────────────────────────────────
echo ""
echo "[9] Verification (advisory)..."
if [[ -z "${SKIP_GEMINI}" && ${#PATCHED_ENGINES[@]} -gt 0 && -n "${GEMINI_TOKEN}" ]]; then
  for _entry in "${PATCHED_ENGINES[@]}"; do
    _loc="${_entry%%|*}"; _eid="${_entry#*|}"
    _host="$(gemini_host "${_loc}")"
    _get_url="https://${_host}/v1alpha/projects/${PROJECT_ID}/locations/${_loc}/collections/default_collection/engines/${_eid}"
    _obs="$(curl -sS -H "Authorization: Bearer ${GEMINI_TOKEN}" \
      -H "X-Goog-User-Project: ${PROJECT_ID}" "${_get_url}" 2>/dev/null \
      | tr -d ' \n' | grep -oE '"observabilityConfig":\{[^}]*\}' || true)"
    echo "  ${_loc}/${_eid}: ${_obs:-observabilityConfig not visible yet}"
  done
fi
if [[ -n "${TELEMETRY_BUCKET}" ]]; then
  BREF="${TELEMETRY_BUCKET#gs://}"; BREF="${BREF%%/*}"
  echo "  GCS logs: appear a few minutes after the first agent or assistant request."
fi

# ── What to enter in the Straiker UI ────────────────────────────────────────
#
# The credential is deliberately NOT printed. It was previously cat'd into a
# "paste as one" JSON blob, which put a live WIF config / SA key into terminal
# scrollback, CI logs and any screen share — and gave the operator a second,
# competing way to configure the connector. Values go in the UI; the script only
# provisions GCP and reports what to type.
echo ""
if [[ "${DRY_RUN}" == 1 ]]; then
  echo "Dry run complete. No GCP resource was created or modified, so there is"
  echo "nothing to enter in the UI yet — re-run without --dry-run to apply."
  echo ""
  exit 0
fi

echo "Setup complete. Enter the values below in the Straiker UI."
echo ""
if [[ "${ENABLE_WIF}" == 1 ]]; then
  CRED_LABEL="Workload Identity Federation config"
  CRED_PATH="${WIF_CRED_CONFIG_OUT}"
else
  CRED_LABEL="Service account JSON key"
  CRED_PATH="${KEY_FILE}"
fi

echo "==================== Enter these in the Straiker UI ===================="
echo "  GCP project ID:        ${PROJECT_ID}"
echo "  Service account:       ${SA_EMAIL}"
if [[ -n "${TELEMETRY_BUCKET}" ]]; then
  BREF="${TELEMETRY_BUCKET#gs://}"; BREF="${BREF%%/*}"
  echo "  GCS telemetry bucket:  ${BREF}"
  # Report a path only where it differs from the default, so nothing must be copied.
  if [[ -n "${AGENT_PLATFORM_PREFIX}${GEMINI_PREFIX}" ]]; then
    [[ -z "${SKIP_AGENT_PLATFORM}" && -n "${AGENT_PLATFORM_PREFIX}" ]] && \
      echo "  Agent Platform prefix: ${AGENT_PLATFORM_PREFIX}"
    [[ -z "${SKIP_GEMINI}" && "${GEMINI_PRESENT}" -eq 1 && -n "${GEMINI_PREFIX}" ]] && \
      echo "  Gemini prefix:         ${GEMINI_PREFIX}"
  else
    echo "  GCS prefix:            leave blank"
  fi
fi
echo ""
echo "  ${CRED_LABEL}:"
echo "    ${CRED_PATH}"
echo "    Upload/paste this file's contents into the credential field in the UI."
echo "    Keep it out of tickets, chat and shared logs; delete it once onboarded:"
echo "      rm -f ${CRED_PATH}"
echo "======================================================================="
echo ""
if [[ -z "${SKIP_AGENT_PLATFORM}" ]]; then
  echo "Reminder (Agent Platform): set GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY=true and"
  echo "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true on your ADK agents — see prerequisites."
fi
echo ""
