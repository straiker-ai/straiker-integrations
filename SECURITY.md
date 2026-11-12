# Security Policy

## Reporting a vulnerability

Report suspected security issues in this repository to **security@straiker.ai**. Include the
affected release or commit, the asset (for example `platforms/databricks/setup.sh`), a description
of the issue and steps to reproduce it.

Do not open a public GitHub issue for a security report, and do not disclose the issue publicly
until it has been resolved.

## What to expect

- Acknowledgement of the report within three business days.
- An assessment and, where a fix is warranted, a remediation timeline.
- Credit in the release notes on request.

## Scope

This repository contains scripts and templates customers run in their own cloud accounts to grant
Straiker access. In scope: an asset that grants more than its README says, leaks or persists a
credential, can be steered to act on the wrong account or resource, or whose release artifacts can
be tampered with. Issues in the Straiker platform itself should also be sent to security@straiker.ai.

## Releases and verification

Releases are created only from `v*` tags, by the release workflow in this repository. Each release
attaches the assets and a `SHA256SUMS` file. Download assets from a release and check them before
running, for example:

```bash
grep ' databricks-setup.sh$' SHA256SUMS | shasum -a 256 -c -
```

Do not run assets from the `main` branch; it can change at any time.

## Supported versions

The latest release is supported. Fixes are published as a new release.
