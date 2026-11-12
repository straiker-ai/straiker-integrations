# Google Cloud

Two scripts, one per Straiker connection type. Both use the same service account
(`straiker-scanner`) and are safe to run in either order or to re-run.

| Script | Console connection | Reads |
| --- | --- | --- |
| `setup.sh` | Gemini Enterprise & Agent Runtime | Agent Runtime (Vertex AI Agent Engine / Reasoning Engine) telemetry and Gemini Enterprise user-activity logs, exported to a GCS bucket |
| `setup-model-logs.sh` | Vertex AI model logs | Vertex AI request/response logs in BigQuery |

> Imported verbatim from the hosted copy on 2026-11-11; the console still links the hosted copy
> until it switches to this repo's releases. Only the file names changed
> (`gcp-agent-platform-onboarding.sh` is `setup.sh`, `gcp-model-logs-onboarding.sh` is
> `setup-model-logs.sh`).

## What this connects

| Product | What it does with this access |
| --- | --- |
| Discover | Inventories Agent Runtime agents and reads their telemetry; reads Gemini Enterprise activity; reads Vertex AI model request/response logs. |
| Ascend | Not used. |
| Defend | Not used. |

## What it creates in your account

Both scripts work in a single project and are idempotent (existing resources are reused).

**Both scripts**

| Item | Where | Why |
| --- | --- | --- |
| Service account `straiker-scanner@<project>.iam.gserviceaccount.com` (`--sa-name`) | The project | The identity Straiker uses. |
| Credential, one of: **Workload Identity Federation** (default, keyless): pool `<sa-name>-pool`, AWS provider `straiker-aws` trusting the Straiker AWS account ID you are given (attribute condition `assertion.arn.contains(':assumed-role/')`), and `roles/iam.workloadIdentityUser` on the service account for that account; **or** a service-account JSON key, only with `--allow-sa-key` | The project | What Straiker authenticates with. An existing provider whose mapping differs is never rewritten unless you pass `--force-provider-update`. |
| A credential file (WIF config or JSON key) | A new private `mktemp` directory (mode 0700, file 0600) on your machine | Uploaded in the Straiker console. The scripts print its path, not its contents; delete it after onboarding. |

**`setup.sh`** (Gemini Enterprise & Agent Runtime)

| Item | Where | Why |
| --- | --- | --- |
| APIs: storage, cloudresourcemanager, iam, logging; aiplatform and cloudtrace (Agent Runtime); discoveryengine (Gemini); sts and iamcredentials (WIF) | The project | Required by the resources below. |
| `observabilityConfig` with `observabilityEnabled` and **`sensitiveLoggingEnabled`** on every Gemini Enterprise engine in the location(s) (default `global`), or only `--engine-id` ones | Each engine | Produces the activity logs Straiker reads. Sensitive logging records full prompts and responses, which may include personal data; interactive runs ask before enabling it. |
| With `--create-sink`: bucket `agent-engine-logs-<project>` (uniform access, `--bucket-location`, default `us-central1`), sinks `agent-engine-gcs-sink` (Agent Runtime) and `gemini-enterprise-gcs-sink` (Gemini), and `roles/storage.objectCreator` on the bucket for each sink's writer identity | The project | Exports both log streams into one bucket. A sink with the same filter and destination is reused instead of duplicated. |
| `roles/aiplatform.viewer`, `roles/cloudtrace.user` | The project (skipped with `--skip-agent-platform`) | Agent Runtime discovery and traces. |
| `roles/storage.objectViewer` | The telemetry bucket only | Reads the exported logs. |

**`setup-model-logs.sh`** (Vertex AI model logs)

| Item | Where | Why |
| --- | --- | --- |
| APIs: bigquery, aiplatform, iam; sts and iamcredentials (WIF) | The project | Required by the resources below. |
| `roles/bigquery.dataViewer`, `roles/bigquery.jobUser` | The project | Query the request/response log tables. |
| With `--create-datasets`: one dataset per region, `<prefix>_<region>` (default prefix `vertex_ai_logs`), and `roles/bigquery.dataEditor` **at project level** for the Vertex AI service agents (`gcp-sa-aiplatform`, `-cc`, `-re`) | The project | Where Vertex AI writes the logs. It does not turn on request/response logging; do that per [Google's guide](https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/request-response-logging). |

## Prerequisites

- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) signed in (`gcloud auth login`);
  `curl` for Gemini Enterprise; `bq` for model logs (`gcloud components install bq`); `jq` optional.
- Permission to enable APIs, create service accounts and set project IAM policy (for example
  Owner). WIF also needs `iam.serviceAccounts.setIamPolicy` on the service account (for example
  `roles/iam.serviceAccountAdmin`). Enabling Gemini observability needs
  `discoveryengine.engines.update` (Gemini Enterprise Admin).
- For WIF: the 12-digit Straiker AWS account ID, from your Straiker contact.
- For Agent Runtime telemetry: set `GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY=true` and
  `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true` on your ADK agents.

## Run it

```bash
VERSION=v0.1.0   # the latest release: https://github.com/straiker-ai/straiker-integrations/releases
BASE=https://github.com/straiker-ai/straiker-integrations/releases/download/$VERSION
curl -fsSLO "$BASE/google-cloud-setup.sh"
curl -fsSLO "$BASE/SHA256SUMS"
grep ' google-cloud-setup.sh$' SHA256SUMS | shasum -a 256 -c -
chmod +x google-cloud-setup.sh

# See every change first. Read-only describe/list calls still run.
./google-cloud-setup.sh --dry-run --non-interactive --project-id=my-project \
  --create-sink --enable-wif --straiker-aws-account-id=<12 digits>

# Apply. Without flags on a terminal, the script asks for each value.
./google-cloud-setup.sh --project-id=my-project --create-sink \
  --enable-wif --straiker-aws-account-id=<12 digits>
```

The model-logs script is downloaded and verified the same way (`google-cloud-setup-model-logs.sh`):

```bash
./google-cloud-setup-model-logs.sh --dry-run --non-interactive --project-id=my-project \
  --bq-locations=us-central1 --create-datasets --enable-wif --straiker-aws-account-id=<12 digits>
```

Main flags (`--help` lists all):

| Flag | Script | Meaning |
| --- | --- | --- |
| `--project-id=ID` | both | Project to onboard (required). |
| `--enable-wif`, `--straiker-aws-account-id=ID` | both | Keyless credential (recommended). |
| `--allow-sa-key` | both | Permit a long-lived JSON key instead of WIF. |
| `--sa-name=NAME`, `--wif-pool-id`, `--wif-provider-id`, `--wif-cred-config-out=PATH`, `--force-provider-update` | both | Names and output path; see above. |
| `--create-sink`, `--bucket-name`, `--bucket-location`, `--sink-name`, `--gemini-sink-name` | `setup.sh` | Create the bucket and sinks. |
| `--telemetry-bucket=NAME` | `setup.sh` | Use an existing bucket instead. |
| `--gemini-location=LOC`, `--engine-id=ID` (repeatable), `--skip-gemini`, `--skip-agent-platform` | `setup.sh` | Gemini scope. |
| `--agent-platform-log-root`, `--gemini-log-root` | `setup.sh` | Only if your sink nests logs under a folder. |
| `--bq-locations=a,b` (required), `--bq-dataset=PREFIX`, `--bq-table=NAME`, `--create-datasets` | model logs | BigQuery layout. |
| `--dry-run`, `--non-interactive` | both | Print mutations only; never prompt. |

## Values to paste into Straiker

**Gemini Enterprise & Agent Runtime** (from `setup.sh`'s "Enter these in the Straiker UI" block):

| Console field | Value |
| --- | --- |
| GCP project ID | `GCP project ID` |
| Gemini Enterprise bucket name / Agent Runtime bucket name | `GCS telemetry bucket` (the same bucket for both) |
| Gemini Enterprise prefix / Agent Runtime prefix | `Gemini prefix` / `Agent Platform prefix` if printed; otherwise leave blank |
| GCP credentials JSON | Contents of the credential file whose path is printed |

**Vertex AI model logs** (from `setup-model-logs.sh`'s "Straiker UI inputs" block):

| Console field | Value |
| --- | --- |
| GCP project ID | `GCP Project ID` |
| BigQuery dataset prefix | `BigQuery dataset prefix` |
| BigQuery table | `BigQuery table` |
| BigQuery locations | `BigQuery location` |
| GCP credentials JSON | Contents of the credential file whose path is printed |

Then delete the credential file (`rm -f <path>`).

## Rotate or remove

**Rotate**: with WIF there is no secret to rotate; re-run to regenerate the config file. With a
JSON key, re-run to create a new key, update Straiker, then delete the old key:
`gcloud iam service-accounts keys list --iam-account=<sa email>` and
`gcloud iam service-accounts keys delete <key id> --iam-account=<sa email>`.

**Remove**: there is no teardown script. Delete what the scripts created, as applicable:

```bash
gcloud iam service-accounts delete straiker-scanner@my-project.iam.gserviceaccount.com
gcloud iam workload-identity-pools delete straiker-scanner-pool --location=global --project=my-project
gcloud logging sinks delete agent-engine-gcs-sink --project=my-project
gcloud logging sinks delete gemini-enterprise-gcs-sink --project=my-project
```

Deleting the service account leaves its project IAM bindings as `deleted:` members; remove them
with `gcloud projects remove-iam-policy-binding`. The bucket, BigQuery datasets, enabled APIs and
the Gemini `observabilityConfig` hold your data or serve other uses, so remove them only if nothing
else needs them. Remove the integration in the Straiker console too.

## Related

- Straiker docs: https://docs.straiker.ai
- Google Cloud: [Workload Identity Federation with AWS](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds),
  [Vertex AI request/response logging](https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/request-response-logging).
