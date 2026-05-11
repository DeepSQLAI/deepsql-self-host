# DeepSQL Self-Hosted Deployment

Self-hosted Docker deployment for DeepSQL — AI-powered Database Performance Assistant.

---

## Prerequisites

| Requirement | Version |
|---|---|
| Docker Engine / Docker Desktop | 24+; installer can help install if missing |
| Docker Compose | v2 (included with Docker Desktop) |
| curl | any recent version |
| RAM | 4 GB minimum, 8 GB recommended |
| Disk | 5 GB free (Docker images + database storage) |

Supported platforms: Linux (amd64, arm64), macOS (Intel, Apple Silicon), Windows (via Docker Desktop / WSL2).

---

## Quick Start

Run the installer:

```bash
curl -fsSL https://install.deepsql.ai/install.sh | bash
```

If Docker is missing, the installer can bootstrap it before starting DeepSQL:

- Linux: prompts, then runs Docker's official `get.docker.com` convenience installer.
- macOS: prompts, then installs Docker Desktop with `brew install --cask docker` when Homebrew is available, and starts Docker Desktop.
- Windows/WSL2: install Docker Desktop manually first.

The script will ask for:

| Variable | Default | Description |
|---|---|---|
| `AZURE_OPENAI_KEY` | none | DeepSQL-managed Azure OpenAI key |
| `AZURE_OPENAI_ENDPOINT` | none | DeepSQL-managed Azure OpenAI endpoint |
| `DEEPSQL_INITIAL_ADMIN_EMAIL` | `admin@yourcompany.com` | Email for the first admin account |
| `DEEPSQL_INITIAL_ADMIN_PASSWORD` | none | Strong password for the first admin account |

The installer handles the rest:

- Downloads this self-host package into `~/.deepsql/self-host`
- Creates `.env` from `.env.example`
- Auto-generates security secrets (`SECURITY_JWT_SECRET`, `ENCRYPTION_KEY`, `DB_PASSWORD`, `ADMIN_BOOTSTRAP_SECRET`)
- Uses public DeepSQL images from `ghcr.io`
- Uses packaged LLM model defaults after you enter the sensitive key and endpoint
- Starts PostgreSQL + pgvector, Valkey, Backend, and Frontend
- Bootstraps the first admin account, then disables the bootstrap endpoint

Open DeepSQL:

```
http://localhost:3035
```

Log in with username `admin` and the password you entered during install.

For a local checkout, run `./scripts/install.sh` instead of the curl command.

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
| Frontend | 3035 | React UI (nginx) |
| Backend | 9085 | Spring Boot API |
| PostgreSQL | 5432 | Internal vault database with pgvector |
| Valkey | 6379 | Cache (Redis-compatible) |

Override any port in `.env`:

```bash
DEEPSQL_FRONTEND_PORT=4040
DEEPSQL_BACKEND_PORT=9185
DEEPSQL_POSTGRES_PORT=5433
DEEPSQL_VALKEY_PORT=6380
```

Then restart: `./scripts/install.sh`.

---

## Upgrading

Re-run the installer:

```bash
curl -fsSL https://install.deepsql.ai/install.sh | bash
```

The installer refreshes the self-host package and pulls the current public images. Your `.env`, data volumes, connections, settings, and chat history are preserved.

From an existing local checkout or install directory, you can also run:

```bash
./scripts/install.sh
```

### Frontend Hotfix (no image pull required)

For small UI fixes, DeepSQL may provide a bundle URL instead of a full image update:

```bash
./scripts/update-frontend.sh <BUNDLE_URL>
```

This downloads the pre-built frontend files and hot-swaps them into the running container — no restart, no image pull, no downtime.

---

## Vector Store

DeepSQL self-host uses PostgreSQL + pgvector for RAG storage by default. Embeddings are stored locally in the PostgreSQL vault database.

```bash
VECTOR_STORE_TYPE=pgvector
AZURE_SEARCH_ENABLED=false
```

The `docker-compose.yml` uses the `pgvector/pgvector:pg18` image, which includes the extension pre-installed. The installer sets `SPRING_AUTOCONFIGURE_EXCLUDE` to disable Azure vector-store autoconfiguration.

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

The installer enables admin bootstrap only for first-run account creation. After the admin account is created, it writes `SECURITY_ADMIN_BOOTSTRAP_ENABLED=false` to `.env` and recreates the backend container with bootstrap disabled.

### Credential Storage

Database connection credentials are encrypted at rest using AES-GCM with the `ENCRYPTION_KEY` in your `.env`. Keep this key safe — if lost, stored credentials cannot be decrypted.

### Network Security

- The backend API requires JWT authentication for all endpoints.
- CORS is restricted to the origins in `CORS_ALLOWED_ORIGINS` (defaults to `http://localhost:*`).
- If exposing DeepSQL beyond localhost, place it behind a reverse proxy with TLS.

### Private Access via AWS SSM Port Forwarding

If you want the UI reachable only from inside your AWS account — with no open ports or public load balancer — use SSM Session Manager to tunnel a local port directly to the instance.

**Prerequisites**: the EC2 instance must have the SSM agent running and an IAM role with `AmazonSSMManagedInstanceCore`.

```bash
aws ssm start-session \
  --region us-west-2 \
  --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=3035,localPortNumber=3035
```

Then open `http://localhost:3035` in your browser. The tunnel stays open as long as the terminal is running.

- Use `portNumber=3035` (the DeepSQL frontend port) unless you changed `DEEPSQL_FRONTEND_PORT` in `.env`.
- You can use any free `localPortNumber` — e.g. `8080` if 3035 is already in use locally.
- No SSH keys, no bastion host, and no security group ingress rule required — traffic goes over the SSM control plane.

---

## Data Privacy

- All database connections, credentials, and query data remain within your environment.
- DeepSQL does not have network access to your infrastructure.
- The only outbound HTTPS traffic required for AI is to **Azure OpenAI** for chat and embeddings, using the key and endpoint entered during install.
- Vector embeddings are stored locally in pgvector.

---

## Slack Integration (optional)

DeepSQL includes a Slack bot that connects via [Socket Mode](https://api.slack.com/apis/socket-mode) — no inbound webhooks or public URLs required. Users can query their databases directly from Slack.

To enable, set these in `.env`:

```bash
SLACK_ENABLED=true
SLACK_SOCKET_MODE_ENABLED=true
SLACK_APP_TOKEN=xapp-...
SLACK_BOT_TOKEN=xoxb-...
SLACK_SIGNING_SECRET=<your-signing-secret>
SLACK_DEEPSQL_BOT_USERNAME=<deepsql-user-who-owns-allowed-connections>
```

**Recommended**: Create a dedicated non-admin DeepSQL user that owns only the database connections Slack should be allowed to query, then set that username as `SLACK_DEEPSQL_BOT_USERNAME`.

Then restart: `./scripts/install.sh`.

---

## Email Notifications (optional)

To enable email notifications (e.g. alerts, reports), configure SMTP in `.env`:

```bash
EMAIL_HOST=smtp.gmail.com
EMAIL_PORT=587
EMAIL_USERNAME=your-email@gmail.com
EMAIL_PASSWORD=your-app-password
EMAIL_FROM=noreply@yourcompany.com
```

Then restart: `./scripts/install.sh`.

---

## Troubleshooting

### Cannot pull images

```
Error: cannot access Docker images from the registry.
```

DeepSQL images should be public on GitHub Container Registry and should not require `docker login`. Check network access to `ghcr.io` and confirm the image names in `.env` are still:

```bash
DEEPSQL_BACKEND_IMAGE=ghcr.io/deepsqlai/deepsql-self-host-backend:latest
DEEPSQL_FRONTEND_IMAGE=ghcr.io/deepsqlai/deepsql-self-host-frontend:latest
```

### Backend not healthy

Check the backend logs:

```bash
docker compose --project-name deepsql-selfhost logs backend --tail=100
```

Common causes:
- The PostgreSQL container did not start in time — re-run `./scripts/install.sh`.
- The public images could not be pulled from `ghcr.io`.

### Cannot connect to my database

- Ensure the database host is reachable from inside the Docker network.
- If the database is on the same machine, use `host.docker.internal` (Docker Desktop) or the host's LAN IP — not `localhost`.
- Check firewall rules allow inbound connections from the Docker subnet.

### Port conflicts

If a port is already in use, override it in `.env`:

```bash
DEEPSQL_FRONTEND_PORT=4040
DEEPSQL_BACKEND_PORT=9185
```

Then restart: `./scripts/install.sh`.

### Reset everything and start fresh

```bash
./scripts/uninstall.sh --purge-data
./scripts/install.sh
```

---

## Support

Contact DeepSQL support at **support@deepsql.io** for assistance with deployment, configuration, or troubleshooting.
