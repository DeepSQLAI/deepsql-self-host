---
title: Uninstall
description: Tear down the DeepSQL stack and remove all state.
---

import { Aside } from '@astrojs/starlight/components';

The installer ships a matching uninstaller. From the install directory (default `~/.deepsql/self-host`):

```bash
./scripts/uninstall.sh
```

Or fetch and pipe:

```bash
curl -fsSL https://install.deepsql.ai/uninstall.sh | bash
```

## What it removes

- All DeepSQL containers (`docker compose down`)
- All DeepSQL volumes — **including the internal Postgres data volume**
- The `~/.deepsql/` directory (the extracted bundle)

## What it does NOT remove

- Docker itself (you installed it, you keep it)
- The `@deepsql/mcp` global npm package
- MCP config entries in Claude Code / Codex / Cursor — remove those manually if you want a clean slate
- Any cloud resources (EC2, IAM, etc.) created via [CloudFormation](/aws/cloudformation/) — delete that stack separately

<Aside type="danger" title="This destroys data">
  Uninstall wipes the internal Postgres volume. Back up anything you care about first.
</Aside>

## Tearing down the CloudFormation stack

If you deployed via CloudFormation, the cleanest way to remove everything is:

```bash
aws cloudformation delete-stack --stack-name deepsql-selfhost --region <region>
```

This removes the EC2 instance, IAM role, support user, Secrets Manager secret, and security group in one shot.
