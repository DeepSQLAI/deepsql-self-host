---
title: Environment variables
description: Override defaults, run headless, or pre-seed credentials with these variables.
---

All variables below are read by `install.sh` if set in your environment when you invoke it. They take precedence over values in `.env`.

## Admin credentials

| Variable | Default | Purpose |
| --- | --- | --- |
| `DEEPSQL_INITIAL_ADMIN_EMAIL` | (prompted) | Skip the email prompt |
| `DEEPSQL_INITIAL_ADMIN_PASSWORD` | (prompted) | Skip the password prompt. Must be 12+ chars |

Set both to run the installer with no TTY (e.g. CI, UserData).

## LLM (Azure OpenAI)

| Variable | Default | Purpose |
| --- | --- | --- |
| `AZURE_OPENAI_KEY` | (bundled) | Override the bundled Azure OpenAI key |
| `AZURE_OPENAI_ENDPOINT` | (bundled) | Override the bundled Azure OpenAI endpoint |
| `DEEPSQL_SKIP_REMOTE_CONFIG` | `false` | Set to `true` to skip the bundled-config fetch entirely |

## MCP & coding agents

| Variable | Default | Purpose |
| --- | --- | --- |
| `DEEPSQL_SKIP_MCP` | `false` | `true` to skip the `npm install -g @deepsql/mcp@latest` step and the agent-config prompt entirely. Use for CI and other headless installs. |

The interactive "which coding agent(s) will you use" prompt also auto-skips when no TTY is attached, so unattended installs (CloudFormation UserData, CI) don't hang.

## Docker

| Variable | Default | Purpose |
| --- | --- | --- |
| `DEEPSQL_INSTALL_DOCKER` | (prompted) | `true` to auto-install Docker without prompting; `false` to refuse and exit |
| `DEEPSQL_SKIP_IMAGE_PULL` | `false` | `true` to skip `docker compose pull` (uses local images) |
| `DEEPSQL_BACKEND_IMAGE` | (from `.env`) | Override the backend image ref |
| `DEEPSQL_FRONTEND_IMAGE` | (from `.env`) | Override the frontend image ref |

## Ports

| Variable | Default | Purpose |
| --- | --- | --- |
| `DEEPSQL_FRONTEND_PORT` | `3035` | Host port for the UI |
| `DEEPSQL_BACKEND_PORT` | `9085` | Host port for the API |
| `DEEPSQL_POSTGRES_PORT` | `5432` | Host port for the internal Postgres |
| `DEEPSQL_VALKEY_PORT` | `6379` | Host port for Valkey |

## Files and project name

| Variable | Default | Purpose |
| --- | --- | --- |
| `DEEPSQL_PROJECT_NAME` | `deepsql-selfhost` | Compose project name |
| `DEEPSQL_ENV_FILE` | `<repo>/.env` | Alternate `.env` file location |
| `DEEPSQL_COMPOSE_FILE` | `<repo>/docker-compose.yml` | Alternate compose file |
| `DEEPSQL_INSTALL_DIR` | `$HOME/.deepsql/self-host` | Where the bundle is extracted when piped from the internet |

## Bootstrap source

| Variable | Default | Purpose |
| --- | --- | --- |
| `DEEPSQL_REPO_OWNER` | `DeepSQLAI` | GitHub org to download the bundle from |
| `DEEPSQL_REPO_NAME` | `deepsql-self-host` | Repo name |
| `DEEPSQL_SELF_HOST_REF` | `main` | Branch or tag (`v1.2.3`) to install |
| `DEEPSQL_SELF_HOST_ARCHIVE_URL` | (computed) | Full archive URL override |

## Vector store / Azure Search (advanced)

| Variable | Default | Purpose |
| --- | --- | --- |
| `VECTOR_STORE_TYPE` | `pgvector` | `pgvector` or `azure` |
| `AZURE_SEARCH_ENABLED` | `false` | Enable Azure AI Search |
| `AZURE_SEARCH_ENDPOINT` | — | Required if `azure` selected |
| `AZURE_SEARCH_API_KEY` | — | Required if `azure` selected |
| `AZURE_SEARCH_INDEX_NAME` | — | Required if `azure` selected |

## Example: fully headless install

```bash
export DEEPSQL_INITIAL_ADMIN_EMAIL='admin@acme.com'
export DEEPSQL_INITIAL_ADMIN_PASSWORD='a-very-strong-password-123'
export DEEPSQL_INSTALL_DOCKER=true
export DEEPSQL_FRONTEND_PORT=8080
curl -fsSL https://install.deepsql.ai/install.sh | bash
```
