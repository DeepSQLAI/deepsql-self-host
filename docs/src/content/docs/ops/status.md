---
title: Status & smoke test
description: Check whether the stack is healthy and exercise the basic flows.
---

Two scripts ship in `scripts/` for day-to-day operations.

## `status.sh`

Reports the state of each container, recent restarts, and HTTP health.

```bash
cd ~/.deepsql/self-host    # or wherever you installed
./scripts/status.sh
```

Sample output:

```
SERVICE         STATE       HEALTH      UPTIME
postgres        running     healthy     2h 14m
valkey          running     healthy     2h 14m
backend         running     healthy     2h 13m
frontend        running     healthy     2h 13m
```

## `smoke-test.sh`

Hits the backend's health endpoint, attempts a login, and runs a trivial query. Use this after install or after any restart.

```bash
./scripts/smoke-test.sh
```

Exit code 0 = healthy. Non-zero = something's wrong; check [troubleshooting](/ops/troubleshooting/).

## Manual checks

```bash
# Backend health
curl -fsS http://localhost:9085/api/actuator/health

# Frontend health
curl -fsSI http://localhost:3035 | head -1

# Container logs
docker compose -p deepsql-selfhost logs --tail=50 backend
docker compose -p deepsql-selfhost logs --tail=50 frontend
```
