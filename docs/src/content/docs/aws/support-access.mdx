---
title: SSM access for DeepSQL support
description: How to grant the DeepSQL team SSM access for troubleshooting, and how to revoke it.
---

import { Aside } from '@astrojs/starlight/components';

When you deploy via [CloudFormation](/aws/cloudformation/) with `CreateSupportUser=Yes` (the default), the stack creates an IAM user the DeepSQL support team can use to SSM into your instance.

## What the support user can do

The IAM policy is scoped narrowly:

- `ssm:StartSession` **only on EC2 instances tagged `deepsql:managed=true`**, in the deploy region
- `ssm:TerminateSession` / `ssm:ResumeSession` only on the user's own sessions
- Read-only `ec2:DescribeInstances` and `ssm:DescribeInstanceInformation` to find instances

That's it. No EC2 modify, no IAM, no S3, no other regions.

## Sharing access

The access key is stored in AWS Secrets Manager — not output in plaintext, not in CloudFormation events.

Two ways to share:

### Option A — grant the DeepSQL principal access to the secret (recommended)

Best if the DeepSQL team has a known IAM principal in their AWS account:

```bash
aws secretsmanager put-resource-policy \
  --region <region> \
  --secret-id <SupportSecretArn> \
  --resource-policy '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::<deepsql-account-id>:role/<deepsql-support-role>"},
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "*"
    }]
  }'
```

DeepSQL fetches the secret on demand. Rotating the key is just rotating the secret.

### Option B — fetch and share the value (less ideal)

```bash
aws secretsmanager get-secret-value \
  --region <region> \
  --secret-id <SupportSecretArn> \
  --query SecretString --output text
```

Output is JSON: `{"AccessKeyId":"AKIA…","SecretAccessKey":"…","Region":"…","InstanceId":"i-…"}`. Share securely (1Password, etc.) and rotate when no longer needed.

## What the DeepSQL team does with it

```bash
# DeepSQL operator configures the support credentials as an AWS profile
aws configure --profile deepsql-support

# Connect
aws --profile deepsql-support ssm start-session \
  --region <region> \
  --target <instance-id>
```

Sessions are logged by AWS — turn on CloudTrail for full audit if your org requires it.

## Revoking access

The cleanest way:

```bash
# Disable the access key (effective immediately)
aws iam update-access-key \
  --user-name deepsql-support \
  --access-key-id <AccessKeyId> \
  --status Inactive
```

Or delete the support user from the stack by updating with `CreateSupportUser=No`:

```bash
aws cloudformation update-stack \
  --stack-name deepsql-selfhost \
  --region <region> \
  --use-previous-template \
  --parameters ParameterKey=CreateSupportUser,ParameterValue=No ... \
  --capabilities CAPABILITY_NAMED_IAM
```

## Without CloudFormation

If you installed manually (not via CloudFormation) and want to grant DeepSQL support access later, attach the same IAM policy to a user of your choice. The policy template is in `cloudformation/deepsql-stack.yaml` under the `SupportUserPolicy` resource — copy the `PolicyDocument` block.
