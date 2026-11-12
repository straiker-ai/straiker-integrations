#!/usr/bin/env bash
# Straiker GCP Model Logs (BigQuery) — onboarding script.
#
# Reuses the shared straiker-scanner service account (same as gcp_agent_platform setup),
# adds BigQuery read permissions, optionally enables request/response logging on
# Vertex AI models, and configures WIF (reusing existing pool if present).
# Single-project only.
#
# If gcp_agent_platform/gcp-agent-platform-onboarding.sh was already run, this script detects the existing SA and
# WIF pool and only adds the delta (BQ roles + optional model logging config).
# Safe to run in either order or re-run.
#
# Usage:
#   ./gcp-model-logs-onboarding.sh [--project-id=...] [--bq-dataset=...] [--bq-locations=...]
#              [--sa-name=...] [--enable-wif] [--straiker-aws-account-id=...]
#              [--gcp-project-number=...] [--wif-pool-id=...] [--wif-provider-id=...]
#              [--wif-cred-config-out=PATH] [--create-datasets] [--non-interactive]

set -euo pipefail

PROJECT_ID=""
SA_NAME="straiker-scanner"
BQ_DATASET=""                 # default resolved to "vertex_ai_logs" after the prompt
BQ_TABLE="request_response_logging"
BQ_TABLE_SET=0                # 1 when --bq-table was passed (suppresses the prompt)
BQ_LOCATIONS=""
NON_INTERACTIVE=""
ENABLE_WIF=""
WIF_FROM_CLI=0
ENABLE_LOGGING=""
ENABLE_LOGGING_SET=0          # 1 when --create-datasets was passed (suppresses the prompt)
STRAIKER_AWS_ACCOUNT_ID=""
GCP_PROJECT_NUMBER=""
WIF_POOL_ID=""
WIF_PROVIDER_ID="straiker-aws"
WIF_CRED_CONFIG_OUT=""
FORCE_PROVIDER_UPDATE=0
DRY_RUN=0
ALLOW_SA_KEY=0
KEY_FILE=""                   # set in [7] only in key mode; declared for set -u

usage() {
  cat <<USAGE
Usage:
  $0 [options]

  Core (flags or interactive on a TTY):
    --project-id=PROJECT_ID          GCP project ID (required)
    --bq-dataset=PREFIX              BigQuery dataset prefix (default: vertex_ai_logs)
    --bq-table=TABLE                 BigQuery table name (default: request_response_logging)
    --bq-locations=LOC[,LOC,...]     Comma-separated regions (required, e.g. us-central1,europe-west1)
                                     Creates one dataset per region: vertex_ai_logs_{region}
    --sa-name=NAME                   default: straiker-scanner

  Model Logging (optional):
    --create-datasets                Create the BigQuery dataset(s) and grant the Vertex AI
                                     service agents write access. Does NOT enable
                                     request/response logging — do that per Google's docs,
                                     since it turns on capture of full prompts/responses.

  WIF (optional):
    --enable-wif                     WIF only: pool + AWS provider + SA bind + cred config
    --straiker-aws-account-id=ID     12-digit Straiker AWS account (required with --enable-wif)
    --gcp-project-number=N           optional; resolved via gcloud if omitted
    --wif-pool-id=ID                 default: \${SA_NAME}-pool
    --wif-provider-id=ID             default: straiker-aws
    --wif-cred-config-out=PATH       default: a private mktemp dir (0700)
    --force-provider-update          rewrite an EXISTING provider's attribute mapping.
                                     Off by default: the default provider name is shared
                                     with the agent-platform script, and rewriting a
                                     provider another integration uses breaks its auth.

  Other:
    --dry-run                        print every mutating command instead of running it.
                                     Nothing in GCP is touched; use this to review the
                                     change set with your platform team first.
    --allow-sa-key                   permit the long-lived service-account-key credential
                                     mode. Off by default — WIF is keyless and preferred.
    --non-interactive                require all inputs via flags; no prompts (for CI)
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --project-id=*)                 PROJECT_ID="${arg#*=}" ;;
    --bq-dataset=*)                 BQ_DATASET="${arg#*=}" ;;
    --bq-table=*)                   BQ_TABLE="${arg#*=}"; BQ_TABLE_SET=1 ;;
    --bq-locations=*)               BQ_LOCATIONS="${arg#*=}" ;;
    --sa-name=*)                    SA_NAME="${arg#*=}" ;;
    --non-interactive)              NON_INTERACTIVE=1 ;;
    --enable-wif)                   ENABLE_WIF=1; WIF_FROM_CLI=1 ;;
    --create-datasets)              ENABLE_LOGGING=1; ENABLE_LOGGING_SET=1 ;;
    --enable-logging)               ENABLE_LOGGING=1; ENABLE_LOGGING_SET=1 ;;  # old name
    --straiker-aws-account-id=*)    STRAIKER_AWS_ACCOUNT_ID="${arg#*=}" ;;
    --gcp-project-number=*)         GCP_PROJECT_NUMBER="${arg#*=}" ;;
    --wif-pool-id=*)                WIF_POOL_ID="${arg#*=}" ;;
    --wif-provider-id=*)            WIF_PROVIDER_ID="${arg#*=}" ;;
    --wif-cred-config-out=*)        WIF_CRED_CONFIG_OUT="${arg#*=}" ;;
    --force-provider-update)        FORCE_PROVIDER_UPDATE=1 ;;
    --dry-run)                      DRY_RUN=1 ;;
    --allow-sa-key)                 ALLOW_SA_KEY=1 ;;
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

if interactive && [[ -z "${BQ_LOCATIONS}" ]]; then
  read -r -p "BigQuery region(s), comma-separated (e.g. us-central1,europe-west1): " BQ_LOCATIONS
fi
[[ -n "${BQ_LOCATIONS}" ]] || die "--bq-locations is required."

# Parse the comma-separated locations. Split on commas AND whitespace: "us-central1,
# europe-west1" is the natural thing to type, and a bare IFS=',' split keeps the
# leading space, which then lands in a dataset name (vertex_ai_logs_ europe_west1)
# and in the v1beta1 API hostname. Empty fields from a trailing comma are dropped.
read -ra LOCATIONS <<< "${BQ_LOCATIONS//,/ }"
[[ "${#LOCATIONS[@]}" -gt 0 ]] || die "--bq-locations contained no usable region."
for _loc in "${LOCATIONS[@]}"; do
  [[ "${_loc}" =~ ^[a-z0-9-]+$ ]] || \
    die "invalid BigQuery region '${_loc}' (expected lowercase letters, digits and hyphens, e.g. us-central1)."
done

# Dataset is a PREFIX: the scanner probes it and its "<prefix>_<region>" variants, so one
# answer covers both a single shared dataset and per-region ones. The table name is used
# verbatim in every dataset it finds.
if interactive && [[ -z "${BQ_DATASET}" ]]; then
  read -r -p "BigQuery dataset prefix [vertex_ai_logs]: " _ds
  [[ -n "${_ds}" ]] && BQ_DATASET="${_ds}"
fi
[[ -n "${BQ_DATASET}" ]] || BQ_DATASET="vertex_ai_logs"

if interactive && [[ "${BQ_TABLE_SET}" -eq 0 ]]; then
  read -r -p "BigQuery table name [${BQ_TABLE}]: " _tbl
  [[ -n "${_tbl}" ]] && BQ_TABLE="${_tbl}"
fi

# Asked because this was previously flag-only: a plain interactive run had no way to create
# the datasets, so it always finished at "no dataset found" with nothing the operator could
# do from inside the script.
if interactive && [[ "${ENABLE_LOGGING_SET}" -eq 0 ]]; then
  cat <<'LOGGING_PROMPT'

BigQuery dataset setup:
  y  Create the dataset(s) and grant the Vertex AI service agents write access
  n  Skip — the dataset already exists
LOGGING_PROMPT
  read -r -p "Choice [y]: " _log_choice
  case "${_log_choice}" in
    y|Y|"") ENABLE_LOGGING=1 ;;
    n|N)    ENABLE_LOGGING="" ;;
    *)      die "Invalid choice (use y or n)." ;;
  esac
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "Error: gcloud CLI not found in PATH" >&2
  exit 1
fi
# bq ships with the Cloud SDK but is a separate component, so gcloud alone is not
# enough. Every dataset create and check below goes through it, and a missing bq
# surfaces as "could not check" on each region — which reads like a permissions
# problem rather than a missing tool.
if ! command -v bq >/dev/null 2>&1; then
  echo "Error: bq CLI not found in PATH (install with: gcloud components install bq)" >&2
  exit 1
fi
# Credential mode
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
  [[ -n "${STRAIKER_AWS_ACCOUNT_ID}" ]] || die "WIF requires --straiker-aws-account-id=."
  [[ "${STRAIKER_AWS_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]] || die "Straiker AWS account ID must be exactly 12 digits."
fi

HOME_PROJECT="$PROJECT_ID"
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
  # Pool, provider and output path are PROMPTED, not silently defaulted. The default
  # provider name is shared with the agent-platform script, so a customer who has
  # already onboarded that connector must be able to point this run somewhere else
  # instead of unknowingly converging on their existing provider.
  if interactive; then
    read -r -p "WIF pool ID [${WIF_POOL_ID}]: " _pool
    [[ -n "${_pool}" ]] && WIF_POOL_ID="${_pool}"
    read -r -p "WIF AWS provider ID [${WIF_PROVIDER_ID}]: " _prov
    [[ -n "${_prov}" ]] && WIF_PROVIDER_ID="${_prov}"
    read -r -p "WIF credential config output path [${WIF_CRED_CONFIG_OUT}]: " _out
    [[ -n "${_out}" ]] && WIF_CRED_CONFIG_OUT="${_out}"
  fi
  if [[ -z "${GCP_PROJECT_NUMBER}" ]]; then
    GCP_PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
  fi
  [[ -n "${GCP_PROJECT_NUMBER}" ]] || die "Could not resolve GCP project number."
fi

echo "── Straiker Model Logs (BQ) onboarding ──"
echo "  Project:       ${HOME_PROJECT}"
echo "  SA email:      ${SA_EMAIL}"
echo "  BQ dataset:    ${BQ_DATASET}"
echo "  BQ table:      ${BQ_TABLE}"
echo "  BQ locations:  ${BQ_LOCATIONS}"
for _loc in "${LOCATIONS[@]}"; do
  _suffix="${_loc//-/_}"
  echo "    → ${BQ_DATASET}_${_suffix} (${_loc})"
done
if [[ "${ENABLE_WIF}" == 1 ]]; then
  echo "  Credentials:   WIF only (${WIF_POOL_ID} / ${WIF_PROVIDER_ID})"
else
  echo "  Credentials:   JSON key only"
fi
echo ""

# ── APIs ──
APIS=(
  bigquery.googleapis.com
  aiplatform.googleapis.com
  iam.googleapis.com
)
if [[ "${ENABLE_WIF}" == 1 ]]; then
  APIS+=(
    sts.googleapis.com
    iamcredentials.googleapis.com
  )
fi

echo "[1] Enabling required APIs in ${HOME_PROJECT}..."
run gcloud services enable "${APIS[@]}" --project="${HOME_PROJECT}"

# ── Service Account ──
echo "[2] Creating service account ${SA_EMAIL}..."
if gcloud iam service-accounts describe "$SA_EMAIL" --project="${HOME_PROJECT}" >/dev/null 2>&1; then
  echo "  (already exists, skipping create)"
else
  run gcloud iam service-accounts create "$SA_NAME" \
    --display-name="Straiker Scanner" \
    --description="Read-only access for Straiker agent scanning (shared across platforms)." \
    --project="${HOME_PROJECT}"
  if [[ "${DRY_RUN}" != 1 ]]; then
    echo "  waiting 8s for SA propagation..."
    sleep 8
  fi
fi

# ── IAM Roles ──
echo "[3] Binding IAM roles at project level..."

# BigQuery: need jobs.create (to run queries) + tables.getData (to read the log table)
# roles/bigquery.dataViewer gives tables.getData + tables.list + datasets.get
# roles/bigquery.jobUser gives bigquery.jobs.create
ROLES=("roles/bigquery.dataViewer" "roles/bigquery.jobUser")
for ROLE in "${ROLES[@]}"; do
  echo "  binding ${ROLE}"
  run_quiet gcloud projects add-iam-policy-binding "$HOME_PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="$ROLE" \
    --condition=None \
    --quiet
done

# ── BQ Dataset creation ──
if [[ "${ENABLE_LOGGING}" == 1 ]]; then
  # PROJECT_NUM forms the Vertex AI service agent emails in the dataEditor bindings below,
  # so it is resolved even in a dry run — a placeholder would make the plan wrong.
  PROJECT_NUM="${GCP_PROJECT_NUMBER:-$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')}"

  echo "[4] Creating BigQuery datasets (one per region)..."
  for LOCATION in "${LOCATIONS[@]}"; do
    REGION_SUFFIX="${LOCATION//-/_}"
    DS_NAME="${BQ_DATASET}_${REGION_SUFFIX}"

    echo "  ── ${DS_NAME} (${LOCATION}) ──"
    if bq show --project_id="${HOME_PROJECT}" "${DS_NAME}" >/dev/null 2>&1; then
      echo "    dataset already exists"
    else
      run bq mk --location="${LOCATION}" \
        --description="Vertex AI request/response logging (${LOCATION})" \
        "${HOME_PROJECT}:${DS_NAME}"
    fi

    # Grant the Vertex AI service agents bigquery.dataEditor so logging can write
    echo "    granting bigquery.dataEditor to Vertex AI service agents..."
    for SA_SUFFIX in "gcp-sa-aiplatform" "gcp-sa-aiplatform-cc" "gcp-sa-aiplatform-re"; do
      AGENT_SA="service-${PROJECT_NUM}@${SA_SUFFIX}.iam.gserviceaccount.com"
      run_quiet gcloud projects add-iam-policy-binding "${HOME_PROJECT}" \
        --member="serviceAccount:${AGENT_SA}" \
        --role="roles/bigquery.dataEditor" \
        --condition=None \
        --quiet 2>/dev/null || echo "    (warning: could not bind dataEditor on ${AGENT_SA})"
    done

  done

else
  echo "[4] Skipping BQ dataset creation and model logging (not selected)."
  echo "[5] Skipping model logging enablement."
  echo ""
  echo "  IMPORTANT: Ensure request/response logging is already enabled on your models."
  echo "  See: https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/request-response-logging"
  echo "  The scanner looks for '${BQ_DATASET}_{region}' (e.g. ${BQ_DATASET}_us_central1) —"
  echo "  one dataset per region, which is what this script creates."
fi

# ── WIF ──
if [[ "${ENABLE_WIF}" == 1 ]]; then
  echo "[6] Configuring Workload Identity Federation..."
  if gcloud iam workload-identity-pools describe "${WIF_POOL_ID}" \
    --location=global --project="${HOME_PROJECT}" >/dev/null 2>&1; then
    echo "  pool ${WIF_POOL_ID} already exists (reusing)"
  else
    run gcloud iam workload-identity-pools create "${WIF_POOL_ID}" \
      --location=global \
      --display-name="Straiker Scanner" \
      --project="${HOME_PROJECT}"
  fi

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
    # shared with the agent-platform script, so an unconditional update-aws here
    # would rewrite the attribute mapping and condition of a provider that another
    # integration is already authenticating against — breaking it, from a script the
    # operator believes is only onboarding model logs. Any federated identity whose
    # ARN does not contain ':assumed-role/' would stop authenticating immediately.
    _cur_map="$(gcloud iam workload-identity-pools providers describe "${WIF_PROVIDER_ID}" \
      --location=global --workload-identity-pool="${WIF_POOL_ID}" --project="${HOME_PROJECT}" \
      --format='value[delimiter=","](attributeMapping)' 2>/dev/null || true)"
    _cur_cond="$(gcloud iam workload-identity-pools providers describe "${WIF_PROVIDER_ID}" \
      --location=global --workload-identity-pool="${WIF_POOL_ID}" --project="${HOME_PROJECT}" \
      --format='value(attributeCondition)' 2>/dev/null || true)"

    # Compare the mapping as a SET of key=value pairs, order-insensitive. A substring
    # test on 'google.subject' is not enough: a provider mapping
    # google.subject=assertion.arn is a different mapping that would still contain the
    # key, and reusing it silently makes the scanner authenticate under the wrong
    # subject. gcloud prints the map in arbitrary order, hence the sort.
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
      echo "  role bindings, datasets, pool) are already applied and are safe to re-run —"
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
  • Use credential mode "k" (JSON key only) if you can create keys but cannot
    set IAM policy on service accounts.

Re-run this script and pick "k" when prompted (or omit --enable-wif).

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
  # The cred config is a credential: restrict it rather than leaving default perms.
  chmod 600 "${WIF_CRED_CONFIG_OUT}" 2>/dev/null || true
else
  echo "[6] Skipping Workload Identity Federation (JSON key mode)."
fi

# ── Key or WIF output ──
# KEY_FILE is resolved inside the else branch, not up front: secure_outdir() creates a
# directory as a side effect, so calling it in WIF mode littered an empty 0700 dir on
# every run. The path is freshly minted, so the "already exists" case cannot occur.
if [[ "${ENABLE_WIF}" == 1 ]]; then
  echo "[7] Skipping SA JSON key (WIF only)."
elif [[ "${DRY_RUN}" == 1 ]]; then
  # Do not call secure_outdir here: it creates a directory as a side effect, and a
  # dry run that leaves 0700 dirs scattered in TMPDIR is not the "touches nothing"
  # contract --dry-run advertises.
  echo "[7] Creating JSON key in a private mktemp dir..."
  run gcloud iam service-accounts keys create "<private-mktemp-dir>/straiker-key-${HOME_PROJECT}.json" \
    --iam-account="$SA_EMAIL" \
    --project="${HOME_PROJECT}"
else
  KEY_FILE="$(secure_outdir)/straiker-key-${HOME_PROJECT}.json"
  echo "[7] Creating JSON key at ${KEY_FILE}..."
  run gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account="$SA_EMAIL" \
    --project="${HOME_PROJECT}"
  chmod 600 "${KEY_FILE}" 2>/dev/null || true
fi

# ── Setup check ─────────────────────────────────────────────────────────────
# Deliberately does NOT count rows. Logging was enabled seconds ago and no
# model has been called since, so any count here is necessarily 0 — reporting
# it as a finding is noise. This also runs as the operator, not as
# ${SA_NAME}, so it cannot prove the scanner's own access; the Straiker
# Console validates that when you save the connection.
echo ""
echo "[8] Checking datasets exist..."
# Exactly the names the scanner probes: "<prefix>_<region>", one per region.
_DS_NAMES=()
for LOCATION in "${LOCATIONS[@]}"; do
  _DS_NAMES+=("${BQ_DATASET}_${LOCATION//-/_}")
done
_DS_FOUND=0
_DS_FOUND_NAMES=()
for DS_NAME in "${_DS_NAMES[@]}"; do
  echo -n "  ${DS_NAME}: "
  # bq writes errors to stdout and exits non-zero, and hard-wraps at ~72 cols
  # (splitting tokens), so capture both streams and match a single-line copy.
  # Only a genuine "Not found: Dataset" is reported as missing — an expired
  # token, a metadata-permission error or an API outage must not masquerade
  # as a missing dataset.
  DS_OUT="$(bq show --project_id="${HOME_PROJECT}" "${DS_NAME}" 2>&1)" && DS_RC=0 || DS_RC=$?
  DS_1LINE="$(tr -s '[:space:]' ' ' <<<"${DS_OUT}")"
  if [[ "${DS_RC}" -ne 0 ]]; then
    if grep -qi "not found: dataset" <<<"${DS_1LINE}"; then
      echo "not present"
    else
      echo "could not check — ${DS_1LINE:0:150}"
    fi
    continue
  fi
  _DS_FOUND=1
  _DS_FOUND_NAMES+=("${DS_NAME}")
  TB_OUT="$(bq show --project_id="${HOME_PROJECT}" "${DS_NAME}.${BQ_TABLE}" 2>&1)" && TB_RC=0 || TB_RC=$?
  TB_1LINE="$(tr -s '[:space:]' ' ' <<<"${TB_OUT}")"
  if [[ "${TB_RC}" -eq 0 ]]; then
    echo "dataset + ${BQ_TABLE} table ready"
  elif grep -qi "not found: table" <<<"${TB_1LINE}"; then
    echo "dataset ready; ${BQ_TABLE} appears on the first logged model call"
  else
    echo "dataset ready; table check inconclusive — ${TB_1LINE:0:120}"
  fi
done

# Advise only when nothing matched: one found dataset is enough for the scanner, so a
# missing sibling is not a problem worth flagging.
if [[ "${_DS_FOUND}" -eq 0 ]]; then
  if [[ -n "${ENABLE_LOGGING}" ]]; then
    echo "  => none found; creation failed — check the [4] output above."
  else
    if interactive; then
      echo "  => none found; create one, or re-run and choose to enable logging."
    else
      echo "  => none found; create one, or re-run with --create-datasets."
    fi
  fi
fi

echo ""
echo "To confirm logs are flowing: call a model in one of these regions, wait"
echo "2-5 minutes, then query the region's table. Until a model is called there"
echo "is nothing to log, so an empty table at this point is expected."

echo ""
if [[ "${DRY_RUN}" == 1 ]]; then
  # No credential was minted, so the UI block would name a file that does not exist
  # and tell the operator to paste its contents — and then to rm -f it.
  echo "Dry run complete. No GCP resource was created or modified, so there is"
  echo "nothing to enter in the UI yet — re-run without --dry-run to apply."
  echo ""
  exit 0
fi

echo "Setup complete. Paste the values below into the Straiker UI."
echo ""
echo "==================== Straiker UI inputs ===================="
echo "GCP Project ID:          ${PROJECT_ID}"
echo "BigQuery dataset prefix: ${BQ_DATASET}"
echo "BigQuery table:          ${BQ_TABLE}"
# "BigQuery location" is the UI field, and it accepts a comma-separated list. Without it the
# scanner probes every region that serves these models — which works, but costs a discovery
# pass, so naming the regions is faster.
echo "BigQuery location:       ${BQ_LOCATIONS}"
echo ""
# Only claim creation when this run actually created them. Without --create-datasets the
# script creates nothing, so listing names under "Datasets created" contradicted step [4]
# ("Skipping BQ dataset creation") and step [8] ("none found") in the same output.
if [[ -n "${ENABLE_LOGGING}" ]]; then
  echo "Datasets created (the scanner finds these from the prefix above):"
  for LOCATION in "${LOCATIONS[@]}"; do
    echo "  ${BQ_DATASET}_${LOCATION//-/_} (${LOCATION})"
  done
elif [[ "${_DS_FOUND}" -eq 0 ]]; then
  echo "No dataset found yet. The scanner will pick one up once it exists under the prefix"
  if interactive; then
    echo "above — either create it, or re-run and choose to enable logging."
  else
    echo "above — either create it, or re-run with --create-datasets."
  fi
else
  echo "Datasets the scanner will read (found in step [8]):"
  for DS_NAME in "${_DS_FOUND_NAMES[@]}"; do
    echo "  ${DS_NAME}"
  done
fi
echo ""
# The credential is deliberately NOT printed. Dumping it inline put a live WIF config
# or SA key into terminal scrollback, CI logs and any screen share. The operator
# uploads the file in the UI; the script only says where it is.
if [[ "${ENABLE_WIF}" == 1 ]]; then
  echo "Workload Identity Federation config -> paste into the credential field in the UI:"
  echo "  ${WIF_CRED_CONFIG_OUT}"
else
  echo "Service account JSON key -> paste into the credential field in the UI:"
  echo "  ${KEY_FILE}"
fi
echo "  Keep it out of tickets, chat and shared logs. Delete it once onboarded."
echo "============================================================"
echo ""
if [[ "${ENABLE_WIF}" != 1 ]]; then
  echo "Note: ${KEY_FILE} is a LONG-LIVED credential. Delete it after entering it in the UI:"
  echo "        rm -f \"${KEY_FILE}\""
else
  echo "Note: delete the config file after entering it in the UI:"
  echo "        rm -f \"${WIF_CRED_CONFIG_OUT}\""
fi
echo ""
