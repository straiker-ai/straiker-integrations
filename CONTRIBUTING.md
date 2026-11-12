# Contributing

## Scope

This repository holds **setup assets and the catalog only**:

- Scripts and templates a customer runs in their own account to grant Straiker access.
- The per-platform reference of exactly what each asset grants.

Runtime integrations (gateways, plugins, guardrails, agents, installers) live in their own
repositories and are only linked from the [catalog](README.md#runtime-integrations):
`straiker-databricks-guardrail`, `apim`, `kong`, `straiker-broker`, `ascend-tunnel`,
`onprem-installer`, `homebrew-tap`. Do not copy their code here.

This repository is public. Never commit a secret, token, tenant or account ID, internal hostname,
internal bucket URL or customer data, including in examples and test fixtures. Use placeholders
such as `<12 digits>` or `https://dbc-1a2b3c4d-5e6f.cloud.databricks.com`.

## Rules for setup assets

Every script or template must:

1. **Stay generic.** Tenant values (account IDs, external IDs, workspace URLs) are arguments or
   parameters, never constants.
2. **Never contact Straiker.** It changes the customer's account and prints the values to paste
   into the console; the customer pastes them.
3. **Print the values to paste**, named as the console names its fields, in the console's order.
4. **Support `--help`, and `--dry-run` when it changes anything.** A dry run prints every change
   and makes none (read-only lookups are fine so the plan shows real IDs). It never shows a secret.
5. **Be idempotent.** Re-running reuses what exists. When a re-run mints a new credential, it says
   how to retire the old one.
6. **Never write secrets to disk.** Hold them in memory and print them once. Where a platform's
   credential must be a file (for example a GCP key), create it in a private `mktemp` directory
   with mode 0600 and tell the customer to delete it.
7. **Pass linting:** `shellcheck` for `*.sh` (clean at the default level for new scripts; CI fails
   on warnings and errors), `PSScriptAnalyzer` for `*.ps1` (CI fails on errors). Bash scripts use
   `set -euo pipefail` and should run on bash 3.2 (the macOS default).

Assets imported verbatim from a previously hosted copy are marked as such in their README and are
not edited in the import change; fixes follow as separate changes.

## Adding a platform

```text
platforms/<platform>/
  README.md        required, follows platforms/_TEMPLATE.md
  setup.sh         the asset (or setup.ps1, template.yaml, ...)
  teardown.sh      when removal is more than one command
```

1. Copy [`platforms/_TEMPLATE.md`](platforms/_TEMPLATE.md) to `platforms/<platform>/README.md` and
   keep every section, in order: **What this connects**, **What it creates in your account**,
   **Prerequisites**, **Run it**, **Values to paste into Straiker**, **Rotate or remove**,
   **Related**.
2. Write the README from what the asset actually does. "What it creates" is an exact list of
   identities, roles, permissions and scopes; reviewers check it line by line against the code.
3. Add a row to the platform table in the top-level [README](README.md).
4. Add the folder to [`.github/CODEOWNERS`](.github/CODEOWNERS).
5. Run locally before opening a pull request:

   ```bash
   shellcheck platforms/<platform>/*.sh
   bash -n platforms/<platform>/*.sh
   platforms/<platform>/setup.sh --help
   platforms/<platform>/setup.sh --dry-run <arguments>
   pwsh -c 'Invoke-ScriptAnalyzer -Path platforms/<platform>/setup.ps1'   # if any
   ```

   State in the pull request what you ran against a real account, and what is not yet verified
   live (also say so in a code comment and in the README).

## Releases

Releases are cut only by pushing a `v*` tag to `main`. The [release workflow](.github/workflows/release.yml)
lints, then publishes each asset as `<platform>-<file>` (for example `databricks-setup.sh`), a
`<platform>.tar.gz` per platform, and `SHA256SUMS`. READMEs link to a pinned release, never to
`main`.
