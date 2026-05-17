---
title: Troubleshooting
description: Common install and runtime failures, and how to fix them.
---

import { Aside } from '@astrojs/starlight/components';

## Install failures

### "Error: required command 'curl' is not installed."

You're on a stripped-down image. Install `curl`, `tar`, and `openssl` via your package manager and re-run.

### "Error: Docker Desktop is installed but the Docker daemon is not running."

macOS only. Start Docker Desktop from Applications, wait for the whale icon to stop animating, and re-run the installer.

### "Error: cannot access Docker images from the registry."

DeepSQL images are on `ghcr.io`. The host needs outbound HTTPS to `ghcr.io`. Most often this is a corporate proxy or VPC endpoint missing.

### Installer hangs at "Waiting for Backend to become healthy"

The backend is starting but failing health checks. Check its logs:

```bash
docker compose -p deepsql-selfhost logs --tail=200 backend
```

Common causes:
- Database password drift (the installer normally fixes this — try `./scripts/install.sh` again)
- Missing or invalid `AZURE_OPENAI_KEY` / `AZURE_OPENAI_ENDPOINT` in `.env`
- Out of memory — `t4g.medium` is below the recommended minimum

### "Error: AZURE_OPENAI_KEY is required."

The bundled config fetch failed (network) and you don't have a value in `.env` or in your environment. Either:
- Allow outbound HTTPS to `install.deepsql.ai`, or
- Export `AZURE_OPENAI_KEY` and `AZURE_OPENAI_ENDPOINT` before running

### Install completes but UI shows "Cannot connect to backend"

The backend container is healthy from Docker's perspective but the frontend can't reach it. Check `CORS_ALLOWED_ORIGINS` in `.env` — it should include the URL you're using to access the UI.

## Runtime failures

### Frontend returns 502 after a while

The backend probably crashed. Check `docker compose ps` and `docker compose logs backend`. Restart with `docker compose -p deepsql-selfhost up -d backend`.

### Database queries to my Aurora/RDS time out

Network reachability. From the DeepSQL instance:

```bash
nc -vz <your-db-endpoint> 5432
```

If this hangs, the DB security group isn't allowing inbound from the DeepSQL security group. See [Networking & Aurora/RDS access](/aws/networking/).

### MCP "command not found: deepsql"

`npm install -g @deepsql/mcp@latest` either wasn't run, or `npm`'s global bin isn't on `PATH`. Check:

```bash
npm root -g       # shows global modules path
which deepsql
```

Add `$(npm bin -g)` to your `PATH` or re-run the installer.

## Asking for help

When opening an issue, include:

1. Installer log: full output, or `/var/log/deepsql-install.log` on CloudFormation deploys
2. `docker compose -p deepsql-selfhost ps`
3. Last 100 lines of the failing service's logs
4. Output of `./scripts/status.sh`
5. Your `.env` file with **all secrets redacted** (passwords, keys, tokens)

File issues at: https://github.com/DeepSQLAI/deepsql-self-host/issues
