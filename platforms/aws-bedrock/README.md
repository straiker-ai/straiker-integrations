# AWS Bedrock

Straiker connects to Amazon Bedrock through CloudFormation templates. The Straiker console builds a
**quick-create** link with your values filled in; you review and deploy the stack in the AWS console,
then paste its output into Straiker.

The templates are in this folder and in every release, with checksums:

| Template | Release asset | What it is |
| --- | --- | --- |
| `straiker-bedrock-iam.yaml` | `aws-bedrock-straiker-bedrock-iam.yaml` | The read-only role (recommended) |
| `straiker-bedrock-iam-user.yaml` | `aws-bedrock-straiker-bedrock-iam-user.yaml` | The same policy on an IAM user with an access key |
| `straiker-bedrock-s3events.yaml` | `aws-bedrock-straiker-bedrock-s3events.yaml` | Optional: forwards new log objects to Straiker as they land |

CloudFormation only creates stacks from templates in Amazon S3, so the console's link uses a copy
that Straiker hosts there. It is the same file as the release asset; compare them with
`SHA256SUMS` before you deploy.

## What this connects

| Product | What it does with this access |
| --- | --- |
| Discover | Inventories Bedrock agents, AgentCore runtimes and gateways, knowledge bases and action groups, and reads Bedrock invocation logs from the S3 buckets you name. |
| Ascend | Not used. |
| Defend | Not used by this stack. See the [Bedrock gateway integration guide](https://docs.straiker.ai/defend-ai/bedrock-gateway-integration). |

## What it creates in your account

The console offers two authentication methods. Both attach the same customer-managed policy.

| Method | Stack name | What it creates |
| --- | --- | --- |
| **IAM Role** (recommended) | `straiker-bedrock-scanner` | IAM role `straiker-bedrock-scanner` that only Straiker's cross-account role can assume, and only with the **External ID** shown in the console (`sts:AssumeRole` with an `sts:ExternalId` condition, plus `sts:TagSession`). No long-lived key. |
| **Access Key** | `straiker-bedrock-scanner` | IAM user `straiker-bedrock` and an access key, returned as stack outputs. The secret key stays readable to anyone who can describe the stack, so prefer the IAM Role method and rotate the key after onboarding. |

**Optional S3 events stack** (`straiker-bedrock-s3events.yaml`): an Amazon EventBridge connection
and API destination for Straiker's ingest webhook, an IAM role that lets EventBridge call only that
destination (`events:InvokeApiDestination`), and a rule that sends S3 object-created events for the
buckets you name. The webhook URL you pass as `WebhookURL` carries Straiker's ingest key, and the API
destination stores that URL as its endpoint, so anyone who can read your EventBridge configuration can
see it. Without this stack, Straiker reads the logs on a schedule instead.

Managed policy `<role or user name>Policy`, read-only:

| Statement | Actions | Resource |
| --- | --- | --- |
| Identity | `sts:GetCallerIdentity` | `*` |
| Bedrock discovery | `bedrock:ListAgents`, `GetAgent`, `ListAgentActionGroups`, `GetAgentActionGroup`, `ListAgentAliases`, `ListAgentVersions`, `ListAgentKnowledgeBases`, `GetKnowledgeBase`, `ListTagsForResource` | `*` |
| AgentCore discovery | `bedrock-agentcore:ListAgentRuntimes`, `GetAgentRuntime`, `ListHarnesses`, `GetHarness`, `GetMemory`, `GetCodeInterpreter`, `GetBrowser`, `ListGateways`, `GetGateway`, `ListGatewayTargets`, `GetGatewayTarget`, `ListTagsForResource` | `*` |
| Lambda | `lambda:GetFunctionConfiguration` (action-group functions) | `*` |
| CloudTrail | `cloudtrail:LookupEvents` | `*` |
| S3 buckets (only if you name buckets) | `s3:ListBucket`, `s3:GetBucketLocation` | The bucket ARNs you enter |
| S3 objects (only if you name buckets) | `s3:GetObject` | `<bucket ARN>/<prefix>*` for each bucket and prefix you enter |

It cannot invoke agents or models, change any resource, or read objects outside the prefixes you
enter.

## Prerequisites

- Permission to create IAM roles (or users), managed policies and CloudFormation stacks
  (`CAPABILITY_NAMED_IAM`) in the AWS account.
- The S3 bucket ARNs and prefixes where Bedrock writes invocation logs, if you want logs read.

## Run it

1. In the Straiker console's Amazon Bedrock onboarding, choose the **Authentication Method**, and
   enter your **S3 Bucket ARN** and **Prefix** values.
2. Open the CloudFormation link the console gives you. Check that the template's resources and
   policy match the tables above, then create the stack.

A dry run is the CloudFormation review page itself, or a change set: nothing is created until you
confirm.

To deploy from a release instead of the console's link, download and verify the template, then
create the stack with the parameter values the console shows:

```bash
VERSION=v0.1.0   # the latest release: https://github.com/straiker-ai/straiker-integrations/releases
BASE=https://github.com/straiker-ai/straiker-integrations/releases/download/$VERSION
curl -fsSLO "$BASE/aws-bedrock-straiker-bedrock-iam.yaml"
curl -fsSLO "$BASE/SHA256SUMS"
grep ' aws-bedrock-straiker-bedrock-iam.yaml$' SHA256SUMS | shasum -a 256 -c -

aws cloudformation create-stack --stack-name straiker-bedrock-scanner \
  --template-body file://aws-bedrock-straiker-bedrock-iam.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameters ParameterKey=ExternalId,ParameterValue=<External ID> \
    ParameterKey=StraikerAssumerRoleArn,ParameterValue=<Straiker role ARN> \
    ParameterKey=BucketArns,ParameterValue='<bucket ARN>' \
    ParameterKey=ObjectArns,ParameterValue='<bucket ARN>/<prefix>*'
```

## Values to paste into Straiker

| Console field | Value |
| --- | --- |
| Role ARN | Stack output `RoleArn` (IAM Role method) |
| Access Key ID | Stack output `AccessKeyId` (Access Key method) |
| Secret Access Key | Stack output `SecretAccessKey` (Access Key method) |
| Regions to Scan | The regions where your Bedrock agents run |

The **External ID** is generated by the console and already filled into the stack; keep it as is.

## Rotate or remove

- **Bucket changes**: when you add buckets or prefixes in Straiker, update the stack with the new
  `BucketArns` and `ObjectArns` parameter values the console shows; Straiker reads only what the
  stack grants.
- **Rotate** (Access Key method): create a new access key for the user, update Straiker, delete the
  old key. The IAM Role method has no long-lived secret.
- **Remove**: delete the CloudFormation stack; it removes the role or user and the policy. Remove
  the integration in the Straiker console too.

## Related

- Straiker docs: https://docs.straiker.ai, [Bedrock gateway integration](https://docs.straiker.ai/defend-ai/bedrock-gateway-integration)
- Network connectivity for private endpoints: [`straiker-broker`](https://github.com/straiker-ai/straiker-broker)
