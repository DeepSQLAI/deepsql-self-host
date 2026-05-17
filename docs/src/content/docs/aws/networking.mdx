---
title: Networking & Aurora/RDS access
description: How to put DeepSQL in the right place to reach your database.
---

import { Aside } from '@astrojs/starlight/components';

DeepSQL connects to your existing Aurora or RDS over private networking — it never crosses the public internet. To make that work, the EC2 instance needs to be in the right VPC with the right security group rules.

## The two networking requirements

1. **Same VPC as the DB.** The CloudFormation `VpcId` parameter must match the VPC your Aurora/RDS cluster lives in.
2. **DB security group allows inbound from the DeepSQL SG.** Add an ingress rule on the DB's security group:
   - Source: the DeepSQL instance security group ID (stack output `InstanceSecurityGroupId`)
   - Port: `5432` (Postgres) or `3306` (MySQL)

## Subnet choice

Pick a **private subnet** (no `0.0.0.0/0` route to an Internet Gateway). Specifically:

- The subnet route table should send `0.0.0.0/0` to a **NAT Gateway** so the installer can pull Docker images, npm packages, and the install bundle.
- The subnet must be able to reach your DB endpoint. If your DB is in private subnets too, they need to share a routing domain (same VPC + no blocking NACLs).

<Aside type="caution" title="No NAT? No internet pulls.">
  If your environment forbids NAT, the alternative is VPC endpoints for SSM (`com.amazonaws.<region>.ssm`, `ssmmessages`, `ec2messages`) plus an S3 gateway endpoint, plus mirroring the DeepSQL container images into your private ECR. That's outside the default CloudFormation template — talk to DeepSQL support.
</Aside>

## Multiple availability zones

The template launches one EC2 instance in one subnet. If you want HA, you would:

- Run multiple stacks in different AZs (each its own instance)
- Front them with an internal NLB
- Point an Aurora reader endpoint at the cluster

Most self-host deployments run a single instance — Aurora handles its own HA, and DeepSQL is stateless aside from its internal Postgres + Valkey.

## Verifying connectivity

Once the stack is up, SSM into the instance and test from there:

```bash
# Resolve the DB endpoint
getent hosts your-db.cluster-xxx.region.rds.amazonaws.com

# Test TCP reachability (install nc first if missing: sudo dnf install nc)
nc -vz your-db.cluster-xxx.region.rds.amazonaws.com 5432
```

If the TCP check hangs or fails, the DB security group isn't allowing inbound from the DeepSQL SG.
