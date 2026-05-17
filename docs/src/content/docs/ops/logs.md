---
title: Logs
description: Where to find logs for each component.
---

## Container logs (live)

```bash
cd ~/.deepsql/self-host

# Tail all services
docker compose -p deepsql-selfhost logs -f

# A specific service
docker compose -p deepsql-selfhost logs -f backend
docker compose -p deepsql-selfhost logs -f frontend
docker compose -p deepsql-selfhost logs -f postgres
docker compose -p deepsql-selfhost logs -f valkey
```

## Installer log (CloudFormation only)

When the installer runs via UserData on the EC2 instance, its full output is captured to:

```
/var/log/deepsql-install.log
```

To read it:

```bash
aws ssm start-session --region <region> --target <instance-id>
# then on the instance:
sudo less /var/log/deepsql-install.log
```

## Persistent log storage

The Docker containers do not write to disk by default — logs are kept by the Docker daemon and rotated according to its `log-opts`. For long-term retention, ship logs to CloudWatch or another aggregator:

```bash
# Example: enable the awslogs Docker driver per-service in docker-compose.yml
services:
  backend:
    logging:
      driver: awslogs
      options:
        awslogs-region: us-east-2
        awslogs-group: /deepsql/backend
        awslogs-create-group: "true"
```

(This is not enabled by default — opt in if you need it.)
