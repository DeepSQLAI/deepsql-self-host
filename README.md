# DeepSQL Self-Hosted Deployment

Self-hosted Docker deployment for DeepSQL — AI-powered Database Performance Assistant.

---

## Prerequisites

| Requirement | Version |
|---|---|
| Docker Engine | 24+ |
| Docker Compose | v2 (included with Docker Desktop) |
| curl | any recent version |
| RAM | 4 GB minimum, 8 GB recommended |
| Disk | 5 GB free (Docker images + database storage) |

Supported platforms: Linux (amd64, arm64), macOS (Intel, Apple Silicon), Windows (via Docker Desktop / WSL2).

---

## Quick Start

### 1. Log in to the container registry

DeepSQL images are hosted on GitHub Container Registry. Use the token provided by DeepSQL:

```bash
echo '<YOUR_TOKEN>' | docker login ghcr.io -u <YOUR_USERNAME> --password-stdin
```

### 2. Configure your environment

```bash
cp .env.example .env
```

Open `.env` and fill in the **required** values:

| Variable | Description |
|---|---|
| `AZURE_OPENAI_KEY` | Azure OpenAI API key (provided by DeepSQL) |
| `AZURE_OPENAI_ENDPOINT` | Azure OpenAI endpoint URL (provided by DeepSQL) |

Security secrets (`SECURITY_JWT_SECRET`, `ENCRYPTION_KEY`, `DB_PASSWORD`) are **auto-generated** by the install script if left as placeholders.

### 3. Set up the admin account

To create the first admin account on install, set these in `.env`:

```bash
SECURITY_ADMIN_BOOTSTRAP_ENABLED=true
ADMIN_BOOTSTRAP_SECRET=<one-time-secret-you-choose>
DEEPSQL_INITIAL_ADMIN_EMAIL=admin@yourcompany.com
DEEPSQL_INITIAL_ADMIN_PASSWORD=<strong-password>
```

### 4. Run the install script

```bash
./scripts/install.sh
```

The script will:
- Auto-generate any missing security secrets
- Pull the DeepSQL images from `ghcr.io`
- Start all services (PostgreSQL, Valkey, Backend, Frontend)
- Wait for health checks to pass
- Bootstrap the admin account (if configured)

### 5. Open DeepSQL

```
http://localhost:3000
```

Log in with username `admin` and the password you set in step 3.

---

## Connecting Your Databases

After logging in, connect DeepSQL to the databases you want to monitor:

1. Go to **Connections** in the sidebar
2. Click **Add Connection**
3. Fill in your database details:
   - **Database type**: PostgreSQL or MySQL
   - **Host**: your database hostname (must be reachable from the Docker network)
   - **Port**: database port (e.g. 5432 for PostgreSQL, 3306 for MySQL)
   - **Database**: database name
   - **Username / Password**: database credentials (stored encrypted)
4. **Test** the connection, then **Save**

**Network access**: The backend container needs to reach your database host. If your database is on the same machine, use the host's IP address (not `localhost`, which resolves to the container itself). On Docker Desktop, you can use `host.docker.internal`.

**SSH tunneling**: DeepSQL supports connecting through an SSH bastion. Enable the SSH toggle when adding a connection and provide the bastion host, port, username, and private key.

---

## Services

| Service | Default Port | Description |
|---|---|---|
| Frontend | 3000 | React UI (nginx) |
| Backend | 8080 | Spring Boot API |
| PostgreSQL | 5432 | Internal vault database with pgvector |
| Valkey | 6379 | Cache (Redis-compatible) |

Override any port in `.env`:

```bash
DEEPSQL_FRONTEND_PORT=8090
DEEPSQL_BACKEND_PORT=8181
DEEPSQL_POSTGRES_PORT=5433
DEEPSQL_VALKEY_PORT=6380
```

Then restart: `./scripts/install.sh`.

---

## Upgrading

Update `.env` with the new version provided by DeepSQL:

```bash
DEEPSQL_BACKEND_IMAGE=ghcr.io/deepsqlai/deepsql-backend:1.1.0
DEEPSQL_FRONTEND_IMAGE=ghcr.io/deepsqlai/deepsql-frontend:1.1.0
```

Then re-run:

```bash
./scripts/install.sh
```

Your data (connections, settings, chat history) is preserved across upgrades.

---

## Vector Store

DeepSQL uses RAG (Retrieval-Augmented Generation) to improve SQL generation accuracy. Two storage backends are supported:

### Mode A: pgvector (default, recommended for self-hosting)

Embeddings are stored locally in the PostgreSQL vault database. No external dependencies — all data stays within your environment.

```bash
VECTOR_STORE_TYPE=pgvector
AZURE_SEARCH_ENABLED=false
```

The `docker-compose.yml` uses the `pgvector/pgvector:pg18` image which includes the extension pre-installed. `install.sh` sets `SPRING_AUTOCONFIGURE_EXCLUDE` automatically to disable the Azure vector store autoconfiguration.

### Mode B: Azure AI Search (optional, faster hybrid search)

If DeepSQL has provisioned an Azure AI Search index for you:

```bash
VECTOR_STORE_TYPE=azure
AZURE_SEARCH_ENABLED=true
AZURE_SEARCH_ENDPOINT=https://<your-resource>.search.windows.net
AZURE_SEARCH_API_KEY=<your-key>
AZURE_SEARCH_INDEX_NAME=dba-agent-training-data
```

---

## Useful Commands

```bash
# Check service status and health endpoints
./scripts/status.sh

# Run end-to-end smoke test (login, create connection, introspect schema)
./scripts/smoke-test.sh

# View logs for a specific service
docker compose --project-name deepsql-selfhost logs backend --tail=100
docker compose --project-name deepsql-selfhost logs postgres --tail=100

# Restart a single service
docker compose --project-name deepsql-selfhost restart backend

# Stop and remove containers (data volumes preserved)
./scripts/uninstall.sh

# Stop and remove containers AND all data volumes (destructive)
./scripts/uninstall.sh --purge-data
```

---

## Security

### Admin Bootstrap

The admin bootstrap endpoint is only active when `SECURITY_ADMIN_BOOTSTRAP_ENABLED=true`. After the first admin account is created, set it back to `false` in `.env` and restart the backend:

```bash
docker compose --project-name deepsql-selfhost restart backend
```

### Credential Storage

Database connection credentials are encrypted at rest using AES-GCM with the `ENCRYPTION_KEY` in your `.env`. Keep this key safe — if lost, stored credentials cannot be decrypted.

### Network Security

- The backend API requires JWT authentication for all endpoints.
- CORS is restricted to the origins in `CORS_ALLOWED_ORIGINS` (defaults to `http://localhost:3000`).
- If exposing DeepSQL beyond localhost, place it behind a reverse proxy with TLS.

---

## Data Privacy

- All database connections, credentials, and query data remain within your environment.
- DeepSQL does not have network access to your infrastructure.
- The only outbound HTTPS traffic is to **Azure OpenAI** (for AI chat and embeddings), using the credentials in `.env`.
- If you use pgvector mode, all vector embeddings are stored locally — no data leaves your network for RAG storage.

---

## Troubleshooting

### Cannot pull images

```
Error: cannot access Docker images from the registry.
```

You need to log in to `ghcr.io` first:

```bash
echo '<YOUR_TOKEN>' | docker login ghcr.io -u <YOUR_USERNAME> --password-stdin
```

Contact DeepSQL support if you do not have a token.

### Backend not healthy

Check the backend logs:

```bash
docker compose --project-name deepsql-selfhost logs backend --tail=100
```

Common causes:
- `AZURE_OPENAI_KEY` or `AZURE_OPENAI_ENDPOINT` is still a placeholder value.
- The PostgreSQL container did not start in time — re-run `./scripts/install.sh`.

### Cannot connect to my database

- Ensure the database host is reachable from inside the Docker network.
- If the database is on the same machine, use `host.docker.internal` (Docker Desktop) or the host's LAN IP — not `localhost`.
- Check firewall rules allow inbound connections from the Docker subnet.

### Port conflicts

If a port is already in use, override it in `.env`:

```bash
DEEPSQL_FRONTEND_PORT=8090
DEEPSQL_BACKEND_PORT=8181
```

Then restart: `./scripts/install.sh`.

### Reset everything and start fresh

```bash
./scripts/uninstall.sh --purge-data
cp .env.example .env
# fill in your values again
./scripts/install.sh
```

---

## Support

Contact DeepSQL support at **support@deepsql.io** for assistance with deployment, configuration, or troubleshooting.
