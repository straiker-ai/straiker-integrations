# Databricks

`setup.sh` connects one or more Databricks workspaces to Straiker. It creates (or reuses) up to two
service principals, grants each one only what its product needs, mints OAuth secrets pinned to
narrow scopes, and prints the values to paste into the Straiker console. `teardown.sh` removes them.

The scripts call only the Databricks CLI with your existing login. They send nothing to Straiker
and write nothing to disk.

## What this connects

| Product | What it does with this access |
| --- | --- |
| Discover | Inventories Genie spaces (agents), their tables, permissions and Unity Catalog grants in each workspace. Principal: `straiker-discover`. |
| Ascend | Sends red-team test prompts to the Genie spaces you choose, as a principal with the data access of a typical user. Principal: `straiker-ascend`, created only with `--ascend-spaces`. |
| Defend | Not used by these scripts. Runtime guardrails for Databricks are the [`straiker-databricks-guardrail`](https://github.com/straiker-ai/straiker-databricks-guardrail) app. |

## What it creates in your account

**Discover** (always)

| Item | Where | Why |
| --- | --- | --- |
| Service principal `straiker-discover` (reused if one with that name exists) | Each listed workspace | The identity Straiker uses for Discover. |
| Membership of the `admins` group | Each listed workspace | Genie shows a space's tables and permissions only to the space's editors and managers or to a workspace admin. Without this, Discover sees only the spaces shared with it. |
| OAuth secret pinned to `genie:read`, `access-management:read`, `unity-catalog:read` | The principal | The credential Straiker holds. Databricks enforces the scopes: this secret cannot mint an `all-apis` token, so it cannot run SQL, send Genie prompts, read secrets or manage users, even though the principal is an admin. |

Admin membership gives the principal visibility; the pinned secret is what limits its power. A
token minted from any other secret of this principal would not be limited, so do not create one.

**Ascend** (only with `--ascend-spaces`)

| Item | Where | Why |
| --- | --- | --- |
| Service principal `straiker-ascend` (reused if it exists) | Each workspace that hosts one of the spaces | The identity Ascend prompts Genie as. Not an admin. |
| OAuth secret pinned to `genie` | The principal | Lets Ascend start Genie conversations and nothing else. |
| `CAN_READ` on each Genie space | Genie space permissions | Enough to prompt the space (measured). |
| `CAN_USE` on each space's SQL warehouse | Warehouse permissions | Genie runs its SQL on that warehouse as the caller. |
| `USE CATALOG`, `USE SCHEMA`, `SELECT` on every table in each space | Unity Catalog | Genie answers with the caller's own data permissions and **fails every question in a space if the caller cannot read any one of its tables**. Grants on the built-in `samples` catalog may be refused; that is fine, it is readable by everyone. |

Genie answers the Ascend principal with its own permissions, so give it the access a typical user
of the agent has and no more. **Genie usage by the Ascend principal is billed to your Databricks
workspace.**

## Prerequisites

- [Databricks CLI](https://docs.databricks.com/dev-tools/cli/install.html) (tested with v1.26.0)
  and [`jq`](https://jqlang.org/download/). Bash 3.2 or later (the macOS default works).
- You are a **workspace admin** in every listed workspace, logged in with the CLI:
  `databricks auth login --host https://<workspace> --profile <name>`.
- All workspaces are on one cloud (AWS, Azure or Google Cloud); another cloud is a separate
  integration in Straiker.
- For Ascend: the Genie space IDs (the ID in the space's URL), and permission to edit those spaces
  (the script reads each space's warehouse and table list).

## Run it

```bash
VERSION=v0.1.0   # the latest release: https://github.com/straiker-ai/straiker-integrations/releases
BASE=https://github.com/straiker-ai/straiker-integrations/releases/download/$VERSION
curl -fsSLO "$BASE/databricks-setup.sh"
curl -fsSLO "$BASE/SHA256SUMS"
grep ' databricks-setup.sh$' SHA256SUMS | shasum -a 256 -c -
chmod +x databricks-setup.sh

# See every change first. Read-only lookups run so the plan shows real IDs; nothing is changed
# and no secret is created.
./databricks-setup.sh --dry-run --profile my-ws \
  --workspaces https://dbc-1a2b3c4d-5e6f.cloud.databricks.com \
  --ascend-spaces 01ef0123456789abcdef0123456789ab

# Apply.
./databricks-setup.sh --profile my-ws \
  --workspaces https://dbc-1a2b3c4d-5e6f.cloud.databricks.com \
  --ascend-spaces 01ef0123456789abcdef0123456789ab
```

| Argument | Default | Meaning |
| --- | --- | --- |
| `--workspaces URL[,URL...]` | required | Workspace URLs: `https://*.cloud.databricks.com`, `*.azuredatabricks.net` or `*.gcp.databricks.com`. |
| `--profile NAME` | one of the two | CLI profile for every workspace. A profile holds one host, so with several workspaces use `--profile-map`. |
| `--profile-map URL=NAME[,...]` | one of the two | CLI profile per workspace. |
| `--ascend-spaces ID[,ID...]` | none | Genie spaces Ascend may test. Creates the Ascend principal. |
| `--discover-name NAME` | `straiker-discover` | Discover principal name. |
| `--ascend-name NAME` | `straiker-ascend` | Ascend principal name. |
| `--dry-run` | off | Print every command with placeholders; change nothing. |

The script is idempotent: re-running reuses the principals and existing grants. Each run creates a
**new** secret and prints the `databricks service-principal-secrets-proxy delete ...` commands for
the older ones, so you can retire them once Straiker uses the new secret.

The values are printed once, to stdout only. Do not redirect them to a file or paste them into
tickets or chat.

### Not yet verified live

These steps follow documented Databricks APIs but have not yet been run against a live workspace.
If one fails, the script reports it and continues; do the step by hand and re-run.

- Adding the Discover principal to `admins` through the SCIM API (`databricks groups patch`). The
  verified path is the workspace UI: **Settings > Identity and access > Groups > admins > Add members**.
- Adding an existing principal to a second workspace by application ID
  (`databricks service-principals create --application-id ...`). Only multi-workspace runs use
  this. The alternative is the account console: **Workspaces > (workspace) > Permissions**.
- The end-to-end Ascend grant path (Genie space, warehouse and Unity Catalog grants in one run).
  Each call shape was verified on its own.

## Values to paste into Straiker

In the Straiker console's Databricks onboarding form. The script prints these in the form's order.

| Console field | Value |
| --- | --- |
| Cloud | `Cloud` line of the output (AWS, Azure or Google Cloud) |
| Workspace URLs | `Workspace URLs` lines, one per line |
| Databricks account ID | Optional; not needed by the script |
| Discover service principal application ID | `discover_client_id` |
| Discover secret | `discover_client_secret` |
| Allow Ascend to send test prompts to Genie agents | Tick it only if you ran with `--ascend-spaces` |
| Ascend service principal application ID | `ascend_client_id` |
| Ascend secret | `ascend_client_secret` |

Straiker refuses a Discover secret that is not pinned to the scopes above.

## Rotate or remove

**Rotate**: re-run `setup.sh` with the same arguments. It creates a new pinned secret and prints the
delete commands for the old ones. Update the secret on the Databricks integration's
edit page in Straiker, then run the printed delete commands.

**Remove**: download `databricks-teardown.sh` from the same release and verify it the same way.

```bash
./databricks-teardown.sh --dry-run --profile my-ws --workspaces https://dbc-1a2b3c4d-5e6f.cloud.databricks.com
./databricks-teardown.sh --profile my-ws --workspaces https://dbc-1a2b3c4d-5e6f.cloud.databricks.com
```

It lists the principals it found, asks you to type `delete` (or pass `--yes`), deletes their OAuth
secrets, then removes the principals from each workspace, which drops their `admins` membership and
the permissions granted to them there. On identity-federated workspaces the principal can remain in
your Databricks account without any workspace access; an account admin can delete it under
**User management > Service principals**. Remove the integration in the Straiker console too.

## Related

- Straiker docs: https://docs.straiker.ai
- Defend at runtime: [`straiker-databricks-guardrail`](https://github.com/straiker-ai/straiker-databricks-guardrail)
  (guardrail for Databricks Unity Gateway, deployed as a Databricks App) and the
  [Unity Gateway integration guide](https://docs.straiker.ai/defend-ai/databricks-unity-gateway-integration).
- Databricks: [OAuth for service principals](https://docs.databricks.com/dev-tools/auth/oauth-m2m.html),
  [Genie space permissions](https://docs.databricks.com/genie/set-up.html).
