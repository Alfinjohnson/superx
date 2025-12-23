# Configuration Reference

Complete environment variable reference for SuperX Orchestrator.

## Overview

SuperX is configured primarily through environment variables, with sensible defaults for development. Configuration is processed in two phases:

1. **Compile-time** (`config/config.exs`) - Static configuration
2. **Runtime** (`config/runtime.exs`) - Environment variables

## Quick Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 4000 | HTTP server port |
| `SUPERX_PERSISTENCE` | postgres | Storage mode |
| `DATABASE_URL` | — | PostgreSQL URL |
| `AGENTS_FILE` | — | Agents YAML path |

---

## Server Configuration

### `PORT`

HTTP server listening port.

| | |
|---|---|
| **Default** | `4000` |
| **Example** | `PORT=8080` |

### `SECRET_KEY_BASE`

Secret key for cryptographic operations. **Required in production.**

| | |
|---|---|
| **Default** | Random (dev only) |
| **Example** | `SECRET_KEY_BASE=$(openssl rand -base64 64)` |

Generate a secure key:

```bash
# Linux/macOS
openssl rand -base64 64

# PowerShell
[Convert]::ToBase64String((1..64 | ForEach-Object { Get-Random -Maximum 256 }) -as [byte[]])
```

---

## Persistence

### `SUPERX_PERSISTENCE`

Storage backend selection.

| | |
|---|---|
| **Default** | `postgres` |
| **Values** | `postgres`, `memory` |

| Mode | Use Case | Data Durability |
|------|----------|-----------------|
| `postgres` | Production, multi-node | Persistent |
| `memory` | Development, testing, edge | Ephemeral (lost on restart) |

```bash
# Memory mode (no database required)
SUPERX_PERSISTENCE=memory mix run --no-halt

# PostgreSQL mode (default)
SUPERX_PERSISTENCE=postgres mix run --no-halt
```

---

## Database Configuration

Configure PostgreSQL connection. Use either `DATABASE_URL` (recommended) or individual variables.

### `DATABASE_URL`

PostgreSQL connection URL. Takes precedence over individual DB_* variables.

| | |
|---|---|
| **Default** | — |
| **Format** | `ecto://user:password@host:port/database` |
| **Example** | `DATABASE_URL=ecto://postgres:secret@db.example.com:5432/superx_prod` |

### Individual Database Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_HOST` | `localhost` | PostgreSQL hostname |
| `DB_PORT` | `5432` | PostgreSQL port |
| `DB_USER` | `postgres` | Database username |
| `DB_PASSWORD` | `postgres` | Database password |
| `DB_NAME` | `superx_dev` | Database name |
| `DB_POOL_SIZE` | `10` (dev), `20` (prod) | Connection pool size |

```bash
# Using individual variables
DB_HOST=db.example.com \
DB_PORT=5432 \
DB_USER=superx \
DB_PASSWORD=secret \
DB_NAME=superx_prod \
DB_POOL_SIZE=20 \
mix run --no-halt
```

### Connection Pool Settings

```elixir
# config/runtime.exs
config :orchestrator, Orchestrator.Repo,
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10")),
  queue_target: 50,      # Target queue time (ms)
  queue_interval: 1000   # Queue check interval (ms)
```

---

## Agent Configuration

### `AGENTS_FILE`

Path to YAML file defining agents loaded at startup.

| | |
|---|---|
| **Default** | — (no file loaded) |
| **Example** | `AGENTS_FILE=/etc/superx/agents.yml` |

**File format:**

```yaml
agents:
  # Minimal configuration
  - name: simple_agent
    url: https://agent.example.com/.well-known/agent.json

  # With authentication
  - name: auth_agent
    url: https://secure.example.com/.well-known/agent.json
    bearer: "your-bearer-token"

  # Full configuration
  - name: full_agent
    url: https://agent.example.com/.well-known/agent.json
    bearer: "token"
    push:
      url: https://myapp.com/webhooks/agent
      hmacSecret: "webhook-secret"
    config:
      maxInFlight: 5
      failureThreshold: 3
      failureWindowMs: 60000
      cooldownMs: 30000
```

### Legacy Agent Variables

For single-agent deployments (deprecated, use `AGENTS_FILE` instead):

| Variable | Default | Description |
|----------|---------|-------------|
| `A2A_REMOTE_URL` | — | Default agent card URL |
| `A2A_REMOTE_BEARER` | — | Bearer token for default agent |

---

## HTTP Client Configuration

Configure the Finch HTTP client used for agent communication.

| Variable | Default | Description |
|----------|---------|-------------|
| `HTTP_TIMEOUT` | `30000` | Default request timeout (ms) |
| `HTTP_CARD_TIMEOUT` | `5000` | Agent card fetch timeout (ms) |
| `HTTP_POOL_SIZE` | `50` | Connection pool size |

```bash
# Increase for high-throughput deployments
HTTP_POOL_SIZE=100 HTTP_TIMEOUT=60000 mix run --no-halt
```

---

## Agent Worker Configuration

Per-agent resilience settings. These are defaults; override per-agent via `agents/upsert` or YAML config.

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_MAX_IN_FLIGHT` | `10` | Max concurrent requests per agent |
| `AGENT_FAILURE_THRESHOLD` | `5` | Failures before circuit opens |
| `AGENT_FAILURE_WINDOW_MS` | `30000` | Failure counting window (ms) |
| `AGENT_COOLDOWN_MS` | `30000` | Wait before testing recovery (ms) |
| `AGENT_CALL_TIMEOUT` | `15000` | Default agent call timeout (ms) |

### Circuit Breaker States

```
CLOSED → (failures ≥ threshold) → OPEN → (cooldown) → HALF_OPEN → (success) → CLOSED
                                                           ↓ (failure)
                                                         OPEN
```

---

## Push Notification Configuration

Webhook delivery settings.

| Variable | Default | Description |
|----------|---------|-------------|
| `PUSH_MAX_ATTEMPTS` | `3` | Maximum delivery attempts |
| `PUSH_RETRY_BASE_MS` | `200` | Base delay for exponential backoff |
| `PUSH_JWT_TTL_SECONDS` | `300` | JWT token expiry time |
| `PUSH_JWT_SKEW_SECONDS` | `120` | Allowed clock skew for JWT |

### Retry Schedule

With default settings, retries occur at:
- Attempt 1: Immediate
- Attempt 2: 200ms delay
- Attempt 3: 400ms delay

---

## Clustering Configuration

Configure Erlang node clustering for distributed deployments.

### `CLUSTER_STRATEGY`

Clustering strategy selection.

| | |
|---|---|
| **Default** | — (no clustering) |
| **Values** | `gossip`, `dns`, `kubernetes` |

### Strategy-Specific Variables

#### Gossip Strategy (Development)

```bash
CLUSTER_STRATEGY=gossip
# Uses UDP multicast for discovery
```

#### DNS Strategy (Docker/Kubernetes)

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_DNS_QUERY` | — | DNS name to query |
| `CLUSTER_DNS_POLLING_INTERVAL` | `5000` | Poll interval (ms) |

```bash
CLUSTER_STRATEGY=dns \
CLUSTER_DNS_QUERY=superx.default.svc.cluster.local \
CLUSTER_DNS_POLLING_INTERVAL=5000 \
mix run --no-halt
```

#### Kubernetes Strategy

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_K8S_SELECTOR` | — | Kubernetes label selector |
| `CLUSTER_NODE_BASENAME` | — | Node basename for cluster |

```bash
CLUSTER_STRATEGY=kubernetes \
CLUSTER_K8S_SELECTOR="app=superx" \
CLUSTER_NODE_BASENAME=superx \
mix run --no-halt
```

### Cluster RPC Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_RPC_TIMEOUT` | `5000` | RPC call timeout (ms) |
| `CLUSTER_IN_FLIGHT_TIMEOUT` | `1000` | In-flight query timeout (ms) |

---

## Logging Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_LEVEL` | `info` | Log level: `debug`, `info`, `warning`, `error` |

```bash
# Enable debug logging
LOG_LEVEL=debug mix run --no-halt
```

---

## Configuration Examples

### Development (Memory Mode)

```bash
export SUPERX_PERSISTENCE=memory
export PORT=4000
export LOG_LEVEL=debug

mix run --no-halt
```

### Production (PostgreSQL)

```bash
export SUPERX_PERSISTENCE=postgres
export DATABASE_URL=ecto://user:pass@db.example.com:5432/superx_prod
export PORT=4000
export SECRET_KEY_BASE=$(openssl rand -base64 64)
export AGENTS_FILE=/etc/superx/agents.yml
export LOG_LEVEL=info
export HTTP_POOL_SIZE=100
export DB_POOL_SIZE=20

mix run --no-halt
```

### Docker Compose

```yaml
services:
  orchestrator:
    environment:
      PORT: 4000
      SUPERX_PERSISTENCE: postgres
      DATABASE_URL: ecto://postgres:postgres@db:5432/superx_prod
      AGENTS_FILE: /home/app/agents.yml
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      LOG_LEVEL: info
    volumes:
      - ./agents.yml:/home/app/agents.yml:ro
```

### Kubernetes

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: superx-config
data:
  PORT: "4000"
  SUPERX_PERSISTENCE: "postgres"
  CLUSTER_STRATEGY: "kubernetes"
  CLUSTER_K8S_SELECTOR: "app=superx"
  CLUSTER_NODE_BASENAME: "superx"
  LOG_LEVEL: "info"
---
apiVersion: v1
kind: Secret
metadata:
  name: superx-secrets
stringData:
  DATABASE_URL: "ecto://user:pass@postgres:5432/superx"
  SECRET_KEY_BASE: "your-64-byte-secret-key-base64-encoded"
```

---

## Environment Variable Loading

### Priority Order

1. Shell environment variables
2. `.env` file (development only)
3. Default values

### Using .env Files

For development, create a `.env` file:

```bash
# .env
SUPERX_PERSISTENCE=memory
PORT=4000
LOG_LEVEL=debug
```

Load with:

```bash
# PowerShell
Get-Content .env | ForEach-Object { if ($_ -match '^\s*([^#][^=]*)\s*=\s*(.*)') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2]) } }

# Linux/macOS
export $(cat .env | xargs)
```

---

## Validation

SuperX validates configuration at startup and will fail fast with clear error messages if required variables are missing or invalid.

```
** (RuntimeError) Missing required environment variable: DATABASE_URL
    (orchestrator 0.1.0) lib/orchestrator/application.ex:15: Orchestrator.Application.start/2
```

To test configuration without starting the server:

```bash
mix run -e "IO.inspect(Application.get_all_env(:orchestrator))"
```
