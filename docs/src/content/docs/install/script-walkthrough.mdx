---
title: What install.sh does
description: A step-by-step walkthrough of every action the installer takes, in order.
---

import { Aside, Steps } from '@astrojs/starlight/components';

This page documents exactly what happens when you run:

```bash
curl -fsSL https://install.deepsql.ai/install.sh | bash
```

It's the same script that runs inside the [CloudFormation deploy](/aws/cloudformation/) — there's no second installer.

## The 12 phases, in order

<Steps>

1. **Bootstrap from the internet (if needed).**

   When piped from `curl | bash`, the script has no local `docker-compose.yml`. It downloads the `deepsql-self-host` release archive from GitHub, extracts it to `~/.deepsql/self-host/`, and re-executes itself from there. If you ran the script from a local checkout, this step is skipped.

2. **Capture preset env vars.**

   Reads `AZURE_OPENAI_KEY`, `AZURE_OPENAI_ENDPOINT`, `DEEPSQL_INITIAL_ADMIN_EMAIL`, `DEEPSQL_INITIAL_ADMIN_PASSWORD`, image overrides, and port overrides from your environment so they win over `.env` defaults.

3. **Verify required commands.**

   Checks that `curl` and `openssl` are present. Exits with a clear error if anything is missing.

4. **Ensure Docker is available.**

   - If `docker` isn't installed, the script offers to install it:
     - **Linux**: downloads `get.docker.com` and runs it (as root or via `sudo`).
     - **macOS**: runs `brew install --cask docker` and launches Docker Desktop.
   - Waits up to ~3 minutes for the Docker daemon to come up.
   - On Linux, falls back to `sudo docker` if the current user can't reach the daemon directly.

5. **Create `.env` from the template** (if it doesn't already exist).

   Copies `.env.example` → `.env`. On subsequent runs, your existing `.env` is preserved.

6. **Load `.env` into the current shell.**

   Parses `.env` line by line and exports each `KEY=VALUE`.

7. **Fetch bundled LLM configuration.**

   Silently `curl`s an obscure config URL on `install.deepsql.ai` and extracts `AZURE_OPENAI_KEY` and `AZURE_OPENAI_ENDPOINT`. If your `.env` already has real values (not placeholders), the remote config is ignored. Skip with `DEEPSQL_SKIP_REMOTE_CONFIG=true`.

8. **Auto-generate security secrets.**

   For any of these that are still placeholders, the script generates a fresh value with `openssl rand`:
   - `SECURITY_JWT_SECRET` (64 bytes, base64)
   - `ENCRYPTION_KEY` (32 bytes, base64)
   - `DB_PASSWORD` (16 bytes, base64)
   - `ADMIN_BOOTSTRAP_SECRET` (32 bytes, base64)

9. **Prompt for admin credentials** (only on first install or if bootstrap is still enabled).

   Asks for an email (default: `admin@yourcompany.com`) and a 12+ character password (entered twice). Skip the prompts entirely by setting both as environment variables before running.

10. **Pull DeepSQL images.**

    `docker compose pull backend frontend` from `ghcr.io`. Skip with `DEEPSQL_SKIP_IMAGE_PULL=true` if you've pre-loaded images locally.

11. **Start the stack.**

    - `docker compose up -d postgres valkey` and wait for health.
    - Sync the generated `DB_PASSWORD` with the running Postgres instance.
    - `docker compose up -d` (backend + frontend).
    - Run schema migrations: enable `pg_stat_statements`, create the `db-scheduler` task table.
    - Wait for backend (`/api/actuator/health`) and frontend HTTP endpoints to respond.

12. **Bootstrap the initial admin user.**

    Calls the backend's internal admin-reset endpoint (gated by `ADMIN_BOOTSTRAP_SECRET`) to create/reset the admin login. Then disables the bootstrap flag in `.env` and restarts the backend so the secret can no longer be used.

</Steps>

## After the stack is up

13. **Install the MCP package.**

    Runs `npm install -g @deepsql/mcp@latest`. Skipped with a warning if `npm` is missing.

14. **Configure MCP for your coding agents.**

    Prompts you to pick from Claude Code, Codex, Cursor (or all, or skip). For each selection it runs:

    ```bash
    deepsql mcp config --install --for <agent> --force
    ```

    See [MCP & coding agents](/install/mcp-agents/) for details on what each command writes.

## Idempotency

`install.sh` is safe to re-run.

- Existing `.env` values are preserved
- Auto-generated secrets are only generated once (subsequent runs see real values and skip)
- Admin bootstrap is disabled after first successful run, so re-runs won't reset the admin password
- `docker compose up -d` only restarts changed services

If you want to start fresh, run `./scripts/uninstall.sh` first.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Generic failure — see the last printed error |

The script uses `set -euo pipefail`, so it fails fast on the first error. Look at the message immediately above the exit for the cause.

## Logs

When running via CloudFormation UserData, the full installer output is written to `/var/log/deepsql-install.log` on the instance. When running interactively, output goes to your terminal.
