# Deployment Guide

Production deployment documentation for SuperX Orchestrator.

## Overview

This guide covers deploying SuperX in various environments:
- Docker/Docker Compose
- Kubernetes
- Bare metal/VM

## Prerequisites

- **Runtime**: Elixir 1.19+ / OTP 28+
- **Database**: PostgreSQL 16+ (for production)
- **Container**: Docker 20.10+
- **Memory**: 512MB minimum, 1GB+ recommended
- **CPU**: 1 core minimum, 2+ recommended

---

## Docker Deployment

### Using Pre-built Image

```bash
# Pull and run
docker run -d \
  --name superx \
  -p 4000:4000 \
  -e DATABASE_URL=ecto://user:pass@db:5432/superx \
  -e SECRET_KEY_BASE=$(openssl rand -base64 64) \
  ghcr.io/alfinjohnson/superx:latest
```

### Docker Compose (Recommended)

```yaml
version: '3.8'

services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: superx_prod
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  orchestrator:
    image: ghcr.io/alfinjohnson/superx:latest
    # Or build locally:
    # build:
    #   context: .
    #   dockerfile: Dockerfile
    ports:
      - "4000:4000"
    environment:
      PORT: 4000
      SUPERX_PERSISTENCE: postgres
      DATABASE_URL: ecto://postgres:postgres@db:5432/superx_prod
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      AGENTS_FILE: /home/app/agents.yml
      LOG_LEVEL: info
    volumes:
      - ./agents.yml:/home/app/agents.yml:ro
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/health"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 30s

volumes:
  postgres_data:
```

### Building the Image

```bash
# From repository root
docker build -t superx:latest .

# Multi-platform build
docker buildx build --platform linux/amd64,linux/arm64 -t superx:latest .
```

### Dockerfile Reference

SuperX uses a multi-stage build:

```dockerfile
# Stage 1: Build
FROM elixir:1.19-slim AS builder

WORKDIR /app
ENV MIX_ENV=prod

# Install build dependencies
RUN apt-get update && apt-get install -y git

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Copy and compile dependencies
COPY orchestrator/mix.exs orchestrator/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

# Copy application and compile
COPY orchestrator/ ./
RUN mix compile && mix release

# Stage 2: Runtime
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y \
    libstdc++6 openssl libncurses5 locales curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /home/app
COPY --from=builder /app/_build/prod/rel/orchestrator ./

ENV HOME=/home/app
ENV PORT=4000

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
  CMD curl -f http://localhost:4000/health || exit 1

CMD ["bin/orchestrator", "start"]
```

---

## Kubernetes Deployment

### Deployment Manifest

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: superx
  labels:
    app: superx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: superx
  template:
    metadata:
      labels:
        app: superx
    spec:
      containers:
        - name: superx
          image: ghcr.io/alfinjohnson/superx:latest
          ports:
            - containerPort: 4000
          envFrom:
            - configMapRef:
                name: superx-config
            - secretRef:
                name: superx-secrets
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "1000m"
          livenessProbe:
            httpGet:
              path: /health
              port: 4000
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: 4000
            initialDelaySeconds: 5
            periodSeconds: 5
          volumeMounts:
            - name: agents-config
              mountPath: /home/app/agents.yml
              subPath: agents.yml
              readOnly: true
      volumes:
        - name: agents-config
          configMap:
            name: superx-agents
---
apiVersion: v1
kind: Service
metadata:
  name: superx
spec:
  selector:
    app: superx
  ports:
    - port: 80
      targetPort: 4000
  type: ClusterIP
```

### ConfigMap and Secrets

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
  AGENTS_FILE: "/home/app/agents.yml"
---
apiVersion: v1
kind: Secret
metadata:
  name: superx-secrets
type: Opaque
stringData:
  DATABASE_URL: "ecto://user:password@postgres.default.svc:5432/superx"
  SECRET_KEY_BASE: "your-64-byte-base64-encoded-secret"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: superx-agents
data:
  agents.yml: |
    agents:
      - name: my_agent
        url: https://agent.example.com/.well-known/agent.json
```

### Horizontal Pod Autoscaler

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: superx-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: superx
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
```

### Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: superx-ingress
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
spec:
  rules:
    - host: superx.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: superx
                port:
                  number: 80
```

---

## Database Setup

### PostgreSQL Configuration

Recommended PostgreSQL settings for production:

```sql
-- Create database
CREATE DATABASE superx_prod;

-- Create user
CREATE USER superx WITH PASSWORD 'secure_password';
GRANT ALL PRIVILEGES ON DATABASE superx_prod TO superx;

-- Performance tuning
ALTER SYSTEM SET max_connections = 200;
ALTER SYSTEM SET shared_buffers = '256MB';
ALTER SYSTEM SET effective_cache_size = '768MB';
ALTER SYSTEM SET work_mem = '16MB';
```

### Running Migrations

```bash
# Docker
docker exec -it superx bin/orchestrator eval "Orchestrator.Release.migrate()"

# Kubernetes
kubectl exec -it deployment/superx -- bin/orchestrator eval "Orchestrator.Release.migrate()"

# Local
mix ecto.migrate
```

---

## Production Checklist

### Security

- [ ] Set strong `SECRET_KEY_BASE` (64+ bytes)
- [ ] Use TLS/HTTPS (via load balancer or reverse proxy)
- [ ] Secure database credentials
- [ ] Enable network policies (Kubernetes)
- [ ] Configure webhook HMAC/JWT secrets

### Reliability

- [ ] Configure health checks
- [ ] Set up liveness and readiness probes
- [ ] Configure circuit breaker thresholds
- [ ] Set appropriate timeouts
- [ ] Enable clustering for HA

### Performance

- [ ] Tune database connection pool
- [ ] Configure HTTP client pool
- [ ] Set appropriate `maxInFlight` per agent
- [ ] Enable horizontal scaling

### Observability

- [ ] Configure log aggregation
- [ ] Set up metrics collection
- [ ] Enable telemetry handlers
- [ ] Configure alerting

---

## Scaling

### Horizontal Scaling

SuperX supports horizontal scaling with PostgreSQL:

```
┌─────────────┐
│  Load       │
│  Balancer   │
└──────┬──────┘
       │
   ┌───┴───┐
   │       │
┌──▼──┐ ┌──▼──┐
│Node1│ │Node2│  ← Stateless SuperX instances
└──┬──┘ └──┬──┘
   │       │
   └───┬───┘
       │
┌──────▼──────┐
│  PostgreSQL │  ← Shared state
└─────────────┘
```

### Clustering

For distributed deployments, enable Erlang clustering:

```yaml
# Kubernetes
CLUSTER_STRATEGY: kubernetes
CLUSTER_K8S_SELECTOR: "app=superx"
CLUSTER_NODE_BASENAME: superx

# Docker with DNS
CLUSTER_STRATEGY: dns
CLUSTER_DNS_QUERY: "tasks.superx"
```

### Resource Guidelines

| Workload | Replicas | Memory | CPU |
|----------|----------|--------|-----|
| Light | 1-2 | 512MB | 0.5 |
| Medium | 2-4 | 1GB | 1 |
| Heavy | 4-8 | 2GB | 2 |

---

## Monitoring

### Health Endpoint

```bash
curl http://localhost:4000/health
```

Response:
```json
{
  "status": "ok",
  "persistence": "postgres",
  "database": "connected"
}
```

### Telemetry Events

Attach telemetry handlers for monitoring:

```elixir
# In your monitoring setup
:telemetry.attach_many(
  "metrics-handler",
  [
    [:orchestrator, :agent, :call_stop],
    [:orchestrator, :agent, :call_error],
    [:orchestrator, :agent, :breaker_open],
    [:orchestrator, :push, :push_failure]
  ],
  &MyMetrics.handle_event/4,
  nil
)
```

### Prometheus Metrics

Add prometheus_ex for metrics:

```elixir
# config/config.exs
config :prometheus, Orchestrator.Metrics,
  registry: :default

# lib/orchestrator/metrics.ex
defmodule Orchestrator.Metrics do
  use Prometheus.Metric

  def setup do
    Counter.declare(
      name: :agent_requests_total,
      help: "Total agent requests",
      labels: [:agent, :status]
    )

    Histogram.declare(
      name: :agent_request_duration_seconds,
      help: "Agent request duration",
      labels: [:agent],
      buckets: [0.1, 0.25, 0.5, 1, 2.5, 5, 10]
    )
  end
end
```

### Log Aggregation

Configure JSON logging for production:

```elixir
# config/prod.exs
config :logger, :console,
  format: {Jason, :encode!},
  metadata: [:request_id, :agent, :task_id]
```

---

## Troubleshooting

### Common Issues

#### Database Connection Errors

```
** (DBConnection.ConnectionError) connection not available
```

**Solutions:**
- Check `DATABASE_URL` is correct
- Verify PostgreSQL is running and accessible
- Increase `DB_POOL_SIZE`

#### Circuit Breaker Tripping

```
Agent my_agent circuit breaker opened
```

**Solutions:**
- Check agent health
- Review `failureThreshold` and `cooldownMs`
- Inspect agent logs

#### Memory Issues

```
Ran out of memory
```

**Solutions:**
- Increase container memory limits
- Review `maxInFlight` settings
- Check for memory leaks in agents

### Debugging

```bash
# Check container logs
docker logs superx -f

# Remote console (Docker)
docker exec -it superx bin/orchestrator remote

# Remote console (Kubernetes)
kubectl exec -it deployment/superx -- bin/orchestrator remote

# Inspect state
iex> :sys.get_state(Orchestrator.Agent.Registry)
```

---

## Backup and Recovery

### Database Backup

```bash
# PostgreSQL backup
pg_dump -h localhost -U postgres superx_prod > backup.sql

# Restore
psql -h localhost -U postgres superx_prod < backup.sql
```

### Configuration Backup

```bash
# Export agent configurations
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"agents/list","params":{"includeCard":true}}' \
  > agents_backup.json
```

---

## Upgrades

### Rolling Upgrades

1. Build new image
2. Update deployment with new image
3. Kubernetes performs rolling update

```bash
# Update deployment
kubectl set image deployment/superx superx=ghcr.io/alfinjohnson/superx:v1.2.0

# Watch rollout
kubectl rollout status deployment/superx
```

### Database Migrations

Run migrations before deploying new version:

```bash
# Run migrations
kubectl exec -it deployment/superx -- bin/orchestrator eval "Orchestrator.Release.migrate()"

# Then update image
kubectl set image deployment/superx superx=ghcr.io/alfinjohnson/superx:v1.2.0
```

### Rollback

```bash
# Kubernetes
kubectl rollout undo deployment/superx

# Docker Compose
docker compose down
docker compose up -d --pull always
```
