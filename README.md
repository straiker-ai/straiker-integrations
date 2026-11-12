# straiker-integrations

Setup assets for connecting your cloud and AI platforms to [Straiker](https://www.straiker.ai): the
scripts and templates you run in your own account to grant Straiker access, and a reference of
exactly what each one grants.

Every asset runs with your credentials, takes your tenant values as arguments, prints the values to
paste into the Straiker console, and sends nothing to Straiker. Download them from a
[release](https://github.com/straiker-ai/straiker-integrations/releases) and check them against its
`SHA256SUMS`; do not run copies from `main`.

## Platforms

| Platform | Setup asset | Access granted | Docs |
| --- | --- | --- | --- |
| [Databricks](platforms/databricks/) | `setup.sh`, `teardown.sh` | Discover: a workspace-admin service principal whose secret is pinned to read-only scopes. Ascend (optional): a principal that may prompt chosen Genie spaces and read their tables. | [README](platforms/databricks/README.md) |
| [Azure AI Foundry](platforms/azure-ai-foundry/) | `setup.sh`, `setup.ps1` | Entra service principal with Reader, Monitoring Reader and Foundry User on chosen subscriptions and projects. | [README](platforms/azure-ai-foundry/README.md) |
| [Google Cloud](platforms/google-cloud/) | `setup.sh`, `setup-model-logs.sh` | Service account (keyless WIF by default) with Vertex AI and Trace read plus read on the telemetry bucket, or BigQuery read for model logs. | [README](platforms/google-cloud/README.md) |
| [AWS Bedrock](platforms/aws-bedrock/) | CloudFormation quick-create, served by the Straiker console (not yet in this repo) | IAM role assumable by Straiker with an External ID, read-only on Bedrock and AgentCore, and read on the log buckets you name. | [README](platforms/aws-bedrock/README.md) |

Straiker product documentation: https://docs.straiker.ai

## Runtime integrations

Integrations that run alongside your AI apps live in their own repositories:

| Repository | What it is |
| --- | --- |
| [`straiker-databricks-guardrail`](https://github.com/straiker-ai/straiker-databricks-guardrail) | Straiker guardrail for Databricks Unity Gateway, deployed as a Databricks App |
| [`apim`](https://github.com/straiker-ai/apim) | Straiker guardrails for Azure API Management |
| [`kong`](https://github.com/straiker-ai/kong) | Straiker plugin for Kong Gateway |
| [`straiker-broker`](https://github.com/straiker-ai/straiker-broker) | Broker that connects Straiker into private customer networks |
| [`ascend-tunnel`](https://github.com/straiker-ai/ascend-tunnel) | Tunnel agent for Ascend |
| [`onprem-installer`](https://github.com/straiker-ai/onprem-installer) | Tools and charts for on-premises installs |
| [`homebrew-tap`](https://github.com/straiker-ai/homebrew-tap) | Homebrew tap for Straiker tools |

## Contributing and security

- Adding or changing a platform: [CONTRIBUTING.md](CONTRIBUTING.md).
- Reporting a vulnerability: [SECURITY.md](SECURITY.md).

Licensed under the [Apache License 2.0](LICENSE).
