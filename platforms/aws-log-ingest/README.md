# AWS log ingest

`straiker-log-ingest-s3-reader.yaml` is a CloudFormation template for a read-only IAM role that lets
Straiker read agent logs or traces you export to Amazon S3 (for example Langfuse exports or Bedrock
invocation logs). The Straiker console builds a **quick-create** link with your values filled in;
you review and deploy the stack in the AWS console, then paste its output into Straiker.

The template is in this folder and in every release as `aws-log-ingest-straiker-log-ingest-s3-reader.yaml`,
with checksums. CloudFormation only creates stacks from templates in Amazon S3, so the console's link
uses a copy that Straiker hosts there; it is the same file as the release asset.

## What this connects

| Product | What it does with this access |
| --- | --- |
| Discover | Not used. |
| Ascend | Not used. |
| Defend | Reads the logs or traces in the buckets and prefixes you name, and checks them for attacks and data leaks. |

## What it creates in your account

| Item | Where | Why |
| --- | --- | --- |
| IAM role `straiker-log-ingest-reader` (name configurable) | The account that holds the buckets | The identity Straiker reads with. Only Straiker's cross-account role can assume it, and only with the **External ID** shown in the console (`sts:AssumeRole` with an `sts:ExternalId` condition, plus `sts:TagSession`). No long-lived key. |
| Managed policy `<role name>Policy`: `sts:GetCallerIdentity` | `*` | Lets Straiker confirm which role it is using. |
| Same policy: `s3:ListBucket`, `s3:GetBucketLocation` | The bucket ARNs you enter | Lists the exported files. |
| Same policy: `s3:GetObject` | `<bucket ARN>/<prefix>*` for each bucket and prefix you enter | Reads the exported files. |

It cannot write or delete objects, read outside the prefixes you enter, or touch any other service.

## Prerequisites

- Permission to create IAM roles, managed policies and CloudFormation stacks (`CAPABILITY_NAMED_IAM`)
  in the account that holds the buckets.
- The S3 bucket ARNs and prefixes your logs or traces are exported to.

## Run it

1. In the Straiker console's log ingest onboarding, choose the log format and enter your **S3 Bucket
   ARN** and **Prefix** values.
2. Open the CloudFormation link the console gives you. Check that the template's resources and policy
   match the table above, then create the stack.

To deploy from a release instead, download `aws-log-ingest-straiker-log-ingest-s3-reader.yaml` and
`SHA256SUMS` from the [latest release](https://github.com/straiker-ai/straiker-integrations/releases),
verify the checksum, and create the stack with the parameter values the console shows (`ExternalId`,
`StraikerAssumerRoleArn`, `BucketArns`, `ObjectArns`).

## Values to paste into Straiker

| Console field | Value |
| --- | --- |
| Role ARN | Stack output `RoleArn` |

The **External ID** is filled into the stack by the console; keep it as is.

## Rotate or remove

- **Bucket changes**: update the stack with the new `BucketArns` and `ObjectArns` values the console
  shows; Straiker reads only what the stack grants.
- **Rotate**: nothing to rotate; the role has no long-lived secret.
- **Remove**: delete the CloudFormation stack, which removes the role and the policy, and remove the
  integration in the Straiker console.

## Related

- Straiker docs: https://docs.straiker.ai
