# <Platform name>

<!--
Copy this file to platforms/<platform>/README.md and keep every section, in this order.
Write from what the asset actually does: if the script and this page disagree, the page is wrong.
Never put a secret, tenant ID, internal hostname or customer value in this page or its examples.
-->

One or two sentences: what this asset is (script, template) and what running it gives Straiker.

## What this connects

| Product | What it does with this access |
| --- | --- |
| Discover | ... |
| Ascend | ... (or "Not used") |
| Defend | ... (or "Not used") |

## What it creates in your account

Exact list. Every identity, role, permission, scope, group membership, resource and setting the
asset creates or changes, and at which scope. Say what it never does (for example "never reads
secrets", "cannot run SQL").

| Item | Where | Why |
| --- | --- | --- |
| ... | ... | ... |

## Prerequisites

- Tools and minimum versions.
- Who must run it (the role or admin right needed to grant the access above).
- Anything that must already exist.

## Run it

Download a pinned release, verify its checksum, then run. Never run a copy from `main`.

```bash
VERSION=v0.1.0   # the latest release: https://github.com/straiker-ai/straiker-integrations/releases
BASE=https://github.com/straiker-ai/straiker-integrations/releases/download/$VERSION
curl -fsSLO "$BASE/<platform>-setup.sh"
curl -fsSLO "$BASE/SHA256SUMS"
grep ' <platform>-setup.sh$' SHA256SUMS | shasum -a 256 -c -
chmod +x <platform>-setup.sh

# See every change first; nothing is modified.
./<platform>-setup.sh --dry-run <arguments>

# Apply.
./<platform>-setup.sh <arguments>
```

Arguments table: flag, required or default, meaning.

## Values to paste into Straiker

The console fields, named exactly as the console shows them, in the console's order, and which
line of the script output fills each one.

| Console field | Value |
| --- | --- |
| ... | ... |

## Rotate or remove

- Rotate: how to mint a new credential and retire the old one.
- Remove: the teardown asset or the manual steps, and what remains afterwards.

## Related

- Straiker docs: https://docs.straiker.ai/...
- Runtime integration repos for this platform, if any (linked, not copied).
