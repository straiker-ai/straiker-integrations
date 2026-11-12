# Azure AI Foundry

`setup.sh` (Azure CLI) and `setup.ps1` (Az PowerShell) are twins: they create an Entra app
registration and service principal for Straiker, assign it read roles on the subscriptions you
choose, check with the principal's own credentials that each Foundry project is readable, and print
the values to paste into the Straiker console.

> Imported verbatim from the hosted copy on 2026-11-11; the console still links the hosted copy
> until it switches to this repo's releases.

## What this connects

| Product | What it does with this access |
| --- | --- |
| Discover | Inventories AI Foundry accounts, projects and agents in the chosen subscriptions, and reads agent conversations from Application Insights. |
| Ascend | Not used. |
| Defend | Not used. Runtime guardrails for Azure API Management are the [`apim`](https://github.com/straiker-ai/apim) policy. |

## What it creates in your account

| Item | Where | Why |
| --- | --- | --- |
| Entra app registration and service principal `straiker-foundry-scanner` (reused if an app with that name exists; `--app-name` / `-AppName` changes it) | Your Entra tenant | The identity Straiker uses. |
| Client secret, valid 2 years (appended; existing secrets are kept) | The app registration | The credential Straiker holds. |
| `Reader` | Each chosen subscription | Discovery of subscriptions, Foundry accounts, projects and Application Insights components. |
| `Monitoring Reader` | Each chosen subscription | Application Insights queries; required for agent conversations. |
| `Foundry User` (role ID `53ca6127-db72-4b80-b1b0-d745d6d5456d`, formerly "Azure AI User") | Each chosen subscription **and** each Foundry project | Foundry data plane (listing agents). The project grant takes effect quickly; the subscription grant covers projects added later or a project grant that failed. |

The scripts then verify as the service principal: they list Foundry accounts through ARM, call
`GET /agents` on every project (the call Straiker makes), and run one Application Insights query.
Each project is reported as readable, pending (role still propagating; Straiker re-checks every
scan), denied, or network-blocked (a virtual network, firewall or private endpoint that no role can
reach). Verification retries for up to 10 minutes (`--verify-timeout` / `-VerifyTimeoutMinutes`).

A Foundry account is one that exposes a `*.services.ai.azure.com` endpoint. The bash script also
accepts accounts of kind `AIServices`; the PowerShell script does not.

## Prerequisites

- `Owner` or `User Access Administrator` on every subscription you onboard (needed to create role
  assignments), and the right to create app registrations in Entra.
- Bash: [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) signed in with
  `az login` (add `--tenant` for multi-tenant), plus `python3` and `curl`.
- PowerShell: **PowerShell 7 (`pwsh`)** with the Az module
  (`Install-Module -Name Az -Scope CurrentUser`), signed in with `Connect-AzAccount`. Windows
  PowerShell 5.1 cannot parse the file as published (it is UTF-8 without a byte-order mark).

## Run it

Bash:

```bash
VERSION=v0.1.0   # the latest release: https://github.com/straiker-ai/straiker-integrations/releases
BASE=https://github.com/straiker-ai/straiker-integrations/releases/download/$VERSION
curl -fsSLO "$BASE/azure-ai-foundry-setup.sh"
curl -fsSLO "$BASE/SHA256SUMS"
grep ' azure-ai-foundry-setup.sh$' SHA256SUMS | shasum -a 256 -c -
chmod +x azure-ai-foundry-setup.sh

./azure-ai-foundry-setup.sh                                  # lists subscriptions and asks
./azure-ai-foundry-setup.sh --subscriptions <sub-id>,<sub-id>
```

PowerShell 7:

```powershell
$Version = 'v0.1.0'
$Base = "https://github.com/straiker-ai/straiker-integrations/releases/download/$Version"
Invoke-WebRequest "$Base/azure-ai-foundry-setup.ps1" -OutFile azure-ai-foundry-setup.ps1
Invoke-WebRequest "$Base/SHA256SUMS" -OutFile SHA256SUMS
$expected = ((Select-String -Path SHA256SUMS -Pattern ' azure-ai-foundry-setup.ps1$').Line -split ' ')[0]
if ((Get-FileHash azure-ai-foundry-setup.ps1 -Algorithm SHA256).Hash -ne $expected) { throw 'checksum mismatch' }

./azure-ai-foundry-setup.ps1 -SubscriptionIds <sub-id>,<sub-id>
```

| Bash | PowerShell | Meaning |
| --- | --- | --- |
| `--subscriptions a,b` | `-SubscriptionIds a,b` | Subscriptions to onboard. Omitted: lists the enabled ones in the tenant and asks (Enter = all). |
| `--app-name NAME` | `-AppName NAME` | App registration name (default `straiker-foundry-scanner`). |
| `--verify-only --client-id ID --client-secret S` | `-VerifyOnly -ClientId ID -ClientSecret S` | Assign nothing and create no secret; only enumerate and verify an existing principal. |
| `--verify-timeout MIN` | `-VerifyTimeoutMinutes MIN` | How long to retry projects that are not readable yet (default 10). |

**No dry run.** These scripts have no `--dry-run`; every run creates a new client secret and the
role assignments above. `--verify-only` is the read-only mode, for a principal that already exists.
Passing `--client-secret` on the command line leaves the secret in your shell history.

The scripts exit 1 when any project is denied, 0 otherwise. They print a per-subscription, per-account,
per-project report and ask you to send it to Straiker; they do not send anything themselves.

## Values to paste into Straiker

The scripts end with a "Paste these values into Straiker" block (not printed with `--verify-only`).

| Console field | Value |
| --- | --- |
| Tenant ID | `Tenant ID` |
| Client ID | `Client ID` |
| Client Secret | `Client Secret` (shown once) |
| Subscription IDs (optional) | `Subscription IDs` (leave empty to scan every subscription the principal can read) |

## Rotate or remove

**Rotate**: re-run the script. It reuses the app registration, appends a new 2-year secret and
re-asserts the roles. Update the secret in Straiker, then delete the old one:
`az ad app credential list --id <client id>` and
`az ad app credential delete --id <client id> --key-id <key id>`.

**Remove**: there is no teardown script. Delete the role assignments and the app registration:

```bash
SP_ID=$(az ad sp show --id <client id> --query id -o tsv)
# Repeat per onboarded subscription (subscription and per-project assignments).
az role assignment list --assignee "$SP_ID" --all --subscription <sub-id> --query '[].id' -o tsv \
  | xargs -r az role assignment delete --ids
az ad app delete --id <client id>   # removes the service principal and its secrets
```

Remove the integration in the Straiker console too.

## Related

- Straiker docs: https://docs.straiker.ai/discover/azure-ai-foundry-onboarding
- Defend at runtime: [`apim`](https://github.com/straiker-ai/apim) (guardrails for Azure API
  Management) and the [Azure APIM integration guide](https://docs.straiker.ai/defend-ai/azure-apim-integration).
