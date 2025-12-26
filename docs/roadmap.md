# SuperX Development Roadmap

Strategic roadmap for SuperX Agentic Gateway Orchestrator development.

**Last Updated**: December 26, 2025  
**Current Release**: Phase 1 ✅ Complete  
**Active Work**: Phase 1.5 – Production Readiness

---

## Table of Contents

1. [Current State](#current-state-) - What we have now
2. [Phase 1 – Core Stability](#phase-1--core-stability--complete) - Completed ✅
3. [Phase 1.5 – Production Readiness](#phase-15--production-readiness-in-progress) - **In Progress** 🔄
4. [Phase 2 – Smart Routing](#phase-2--smart-routing) - Planned
5. [Phase 3 – Multi-Protocol Support](#phase-3--multi-protocol--tooling-support) - Planned
6. [Phase 4 – Observability](#phase-4--observability--monitoring) - Planned
7. [Phase 5 – Enterprise Features](#phase-5--enterprise-features) - Planned
8. [Legend & Contributing](#contributing) - How to help

---

## Current State ✅

SuperX is an A2A Protocol gateway with:

- Full A2A v0.3.0 protocol implementation
- Hybrid PostgreSQL + ETS caching for durability with fast reads
- OTP-distributed task management via Horde
- Per-request webhooks for real-time notifications
- Circuit breaker and backpressure patterns
- Push notifications with HMAC/JWT/Token auth
- Erlang clustering support (gossip, DNS, Kubernetes)
- 430+ tests with comprehensive coverage

---

## Phase 1 – Core Stability ✅ Complete

**Story:** *"I want to deploy SuperX and have it reliably persist tasks and agents while maintaining sub-millisecond read performance."*

**Goal**: Stable gateway with hybrid persistence (PostgreSQL + ETS caching).

| Task | Status | Description |
|------|--------|-------------|
| Hybrid PostgreSQL + ETS | ✅ Done | Write-through cache with sub-ms reads |
| Per-request webhooks | ✅ Done | Webhook URLs in request metadata |
| SSE streaming | ✅ Done | Real-time task updates via Server-Sent Events |
| Circuit breaker | ✅ Done | Automatic failure detection and recovery |
| Clustering support | ✅ Done | Multi-node via gossip, DNS, Kubernetes |
| Terminal state protection | ✅ Done | Completed/failed/canceled tasks immutable |

**Delivered**: Stable, clusterable gateway with durable task persistence.

---

## Phase 1.5 – Production Readiness (In Progress)

**Story:** *"I need atomic operations, zero data loss on crashes, protection against split-brain, and automated backups for production deployment."*

**Goal**: Enterprise-grade durability with distributed coordination and disaster recovery.

**Timeline**: 8-12 weeks | **Cost**: +$600-800/month for production infrastructure

### Implementation Overview

SuperX Phase 1.5 adds four critical production features:

```
Phase 1.5.1          Phase 1.5.2              Phase 1.5.3           Phase 1.5.4
PostgreSQL Backend   Distributed Coord.      Backup & Recovery     Observability
80% Complete         0% Complete             0% Complete           0% Complete

Database + Schemas ──► Locks + Health ──► Backups + HA ──► Metrics + Tracing
ACID Guarantees      Split-Brain Prevention  Zero Data Loss   Monitoring Ready
```

---

### Phase 1.5.1: PostgreSQL Backend – 80% Complete

**Objective**: Replace ETS-only storage with PostgreSQL for durability while maintaining performance.

#### Status Summary

| Component | Status | Details |
|-----------|--------|---------|
| Dependencies | ✅ Done | ecto_sql, postgrex, ecto_psql_extras, ex_machina added |
| Database Schema | ✅ Done | Tasks, Agents, PushConfigs tables with indices |
| Ecto Schemas | ✅ Done | Full data models with validation and constraints |
| Cached Store (Task) | ✅ Done | Write-through cache: PostgreSQL + ETS hybrid |
| Cached Store (Agent) | ✅ Done | Write-through cache implementation |
| Persistence Layer | ✅ Done | Configurable adapter selection (Memory/Postgres/Cached) |
| Docker Setup | ✅ Done | Dev + test databases in root docker-compose.yml |
| Base Postgres Store | 🔄 In Progress | Raw PostgreSQL without cache layer |
| Unit Tests | 📋 Planned | Concurrent operation tests, atomicity verification |

#### Key Features Implemented

**Write-Through Cache Pattern**
- All writes go to PostgreSQL (durable) + ETS (fast)
- Reads hit cache first (~0.5ms), fallback to database
- Cache invalidated on writes
- Each node has independent cache (cluster-friendly)

**Database Schema**
```
tasks table:
  - id (string, PK)
  - status (JSONB) - Terminal states immutable
  - message (JSONB)
  - result (JSONB)
  - artifacts (JSONB array)
  - agent_id, context_id (indexed)
  - created_at, updated_at (indexed)

agents table:
  - id (string, PK)
  - url (unique, indexed)
  - bearer token, protocol
  - metadata (JSONB)

push_configs table:
  - id (binary, PK)
  - task_id (FK → tasks, on delete cascade)
  - webhook URL, auth secrets
```

#### Performance Targets

| Metric | ETS Only | PostgreSQL | Cached Postgres |
|--------|----------|------------|-----------------|
| Write latency | 0.1ms | 2-5ms | 2-5ms |
| Read latency (cache hit) | 0.05ms | — | 0.5ms |
| Read latency (cache miss) | — | 2-5ms | 2-5ms |
| Data loss on crash | 100% | 0% | 0% |
| Consistency | Eventual | ACID | ACID |

#### Next Steps for Phase 1.5.1

1. ✅ Implement base PostgreSQL adapter (remove dual cache dependency)
2. 📋 Write comprehensive store tests
3. 📋 Benchmark against performance targets
4. 📋 Document migration strategy for existing deployments

---

### Phase 1.5.2: Distributed Coordination – 0% Complete

**Objective**: Prevent split-brain scenarios and ensure cluster-wide consistency across nodes.

#### Planned Tasks

| Task | Implementation |
|------|-----------------|
| Distributed Locks | PostgreSQL advisory locks (`pg_try_advisory_lock`) for atomic task operations |
| Health Monitoring | Database health checks with circuit breaker (detect failures, prevent cascades) |
| Lock-Based Updates | Status updates protected by locks (prevent race conditions, ensure ordering) |
| Node Coordination | Cross-node task synchronization via database as source of truth |

#### Architecture

```
When updating a task (e.g., status change):

1. Acquire lock via: SELECT pg_try_advisory_lock(hash(task_id))
2. Read current state within transaction
3. Validate state machine (can't update terminal tasks)
4. Apply update
5. Broadcast via PubSub to other nodes
6. Release lock via: SELECT pg_advisory_unlock(lock_id)
```

#### Success Criteria

- ✅ No race conditions on concurrent updates
- ✅ Automatic recovery from node failures
- ✅ Split-brain prevention (database as authority)
- ✅ <100ms lock acquisition time (p99)

---

### Phase 1.5.3: Backup & Recovery – 0% Complete

**Objective**: Achieve zero data loss and sub-minute recovery time for disaster scenarios.

#### Planned Architecture

**PostgreSQL High Availability**
```
Primary (5432) ──► Replica 1 (5433)
                ├──► Replica 2 (5434)
                └──► PgBouncer (6432) - connection pooling

WAL Archiving ──► S3 - continuous incremental backups
```

#### Backup Strategy

| Backup Type | Frequency | Retention | Purpose |
|-------------|-----------|-----------|---------|
| Full backup | Daily @ 2 AM | 30 days | Complete recovery point |
| Incremental | Every 4 hours | 30 days | Reduce backup storage |
| WAL archive | Continuous | 30 days | Point-in-time recovery |

#### Recovery Procedures

1. **From Full Backup** (RTO: 10-15 min)
   - Stop orchestrator
   - Drop and recreate database
   - Restore from pg_dump
   - Start orchestrator

2. **Point-in-Time Recovery** (RTO: 5-10 min)
   - Replay WAL logs up to target timestamp
   - Automatic promotion to primary
   - Clients reconnect seamlessly

#### Success Criteria

- ✅ RPO (Recovery Point Objective): <15 minutes
- ✅ RTO (Recovery Time Objective): <5 minutes
- ✅ Can restore from any point in last 30 days
- ✅ Automated backup verification (restore tests)

---

### Phase 1.5.4: Observability & Monitoring – 0% Complete

**Objective**: Production visibility into database operations and system health.

#### Telemetry Collection

| Metric | Type | Collection Method |
|--------|------|-------------------|
| Query Duration | Histogram | Ecto query telemetry |
| Task Operations | Counter | put/get/update events |
| Cache Hit Rate | Gauge | ETS cache statistics |
| Lock Wait Time | Histogram | Advisory lock latency |
| Replication Lag | Gauge | PostgreSQL metrics |

#### Integration Points

- **Prometheus** - Time-series metrics storage
- **OpenTelemetry** - Distributed tracing context
- **Grafana** - Dashboard templates (query performance, cache stats)
- **Alerting** - Anomaly detection (slow queries, replication lag)

#### Success Criteria

- ✅ All database operations traced
- ✅ <5ms latency dashboard refresh
- ✅ Alert on replication lag >1s
- ✅ Query performance insights available

---

### Phase 1.5 Success Metrics

When complete, SuperX will have:

- ✅ **Atomic operations** - PostgreSQL ACID transactions prevent corruption
- ✅ **Strong consistency** - All nodes read from single database source
- ✅ **Zero data loss** - Replication + automated backups
- ✅ **Split-brain protection** - Distributed locks prevent divergence
- ✅ **Sub-second latency** - Cached reads + connection pooling
- ✅ **Production visibility** - Full metrics and tracing
- ✅ **Disaster recovery** - <5 min RTO, <15 min RPO

---

## Phase 2 – Smart Routing

**Story:** *"My app asks 'analyze this sales data' – it shouldn't need to know which agent handles data analysis. SuperX should figure that out and route to the best available agent."*

**Goal**: Intelligent agent selection based on capabilities, with SuperX always acting as the proxy.

| Task | Status | Description |
|------|--------|-------------|
| Skill-based routing | 📋 Planned | Route based on agent skill declarations |
| Query-based routing | 📋 Planned | Natural language agent selection |
| Load-aware routing | 📋 Planned | Consider agent load and latency |
| Fallback chains | 📋 Planned | Automatic fallback to alternative agents |
| `superx/route` method | 📋 Planned | Query-based agent selection |
| `message/sendAuto` method | 📋 Planned | Auto-route and execute in single call |

### Architecture: SuperX as Gateway

Clients **never** talk directly to agents. SuperX is always the proxy:

```
┌──────────────────────────────────────────────────────────────────┐
│                            CLIENT                                 │
└─────────────────────────────────┬────────────────────────────────┘
                                  │
                                  │ All requests via SuperX
                                  ▼
┌──────────────────────────────────────────────────────────────────┐
│                        SUPERX GATEWAY                             │
│                      http://superx:4000                           │
│                                                                   │
│   ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐  │
│   │superx/route  │  │message/send  │  │ message/sendAuto      │  │
│   │(find agent)  │  │(call agent)  │  │ (route + execute)     │  │
│   └──────────────┘  └──────────────┘  └───────────────────────┘  │
│                                                                   │
│                       Internal Routing                            │
└─────────────────────────────────┬────────────────────────────────┘
                                  │
                  ┌───────────────┼───────────────┐
                  ▼               ▼               ▼
            ┌──────────┐   ┌──────────┐   ┌──────────┐
            │ Agent A  │   │ Agent B  │   │ Agent C  │
            │ (hidden) │   │ (hidden) │   │ (hidden) │
            └──────────┘   └──────────┘   └──────────┘
```

### Usage Patterns

**Pattern 1: Direct Call (Client knows agent)**
```json
{
  "method": "message/send",
  "params": {
    "agent": "data_analyst",
    "message": {"role": "user", "parts": [{"text": "Analyze this data"}]}
  }
}
```

**Pattern 2: Route Then Call (Two-step)**
```json
// Step 1: Ask SuperX which agent to use
{"method": "superx/route", "params": {"query": "I need help with data analysis"}}
// Response: {"agent": "data_analyst", "confidence": 0.92}

// Step 2: Call that agent
{"method": "message/send", "params": {"agent": "data_analyst", "message": {...}}}
```

**Pattern 3: Auto-Route (Single call)**
```json
{
  "method": "message/sendAuto",
  "params": {
    "message": {"role": "user", "parts": [{"text": "Analyze Q4 sales"}]},
    "routingHints": {"skills": ["data-analysis"]}
  }
}
```

### Skill-Based Routing

Match requests to agents based on declared skills from Agent Cards:

```
┌─────────────────────────────────────────────────────────────┐
│  Request: skills: ["data-analysis", "python"]               │
└─────────────────────────────┬───────────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Skill Matcher                             │
│  1. Find agents with ALL required skills                    │
│  2. Score by: skill match + load + latency                  │
│  3. Return best match or fallback                           │
└─────────────────────────────┬───────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
        ┌──────────┐   ┌──────────┐   ┌──────────┐
        │ Agent A  │   │ Agent B  │   │ Agent C  │
        │ Score: 95│   │ Score: 72│   │ Score: 0 │
        │ ✓ MATCH  │   │ partial  │   │ no match │
        └──────────┘   └──────────┘   └──────────┘
```

**Scoring Algorithm:**
- Skill match: 60% weight
- Current load: 20% weight  
- Average latency: 20% weight

### Query-Based Routing

Natural language agent selection without knowing skill names:

| Strategy | Latency | Accuracy | Dependencies |
|----------|---------|----------|--------------|
| Keyword/TF-IDF | ~1ms | Medium | None |
| Embedding similarity | ~50ms | High | Embedding API |
| LLM routing | ~500ms+ | Highest | LLM API |

**Default: Keyword/TF-IDF** (no external dependencies)

### Proposed `superx/route` Method

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "superx/route",
  "params": {
    "query": "I need help with data analysis",
    "constraints": {
      "skills": ["data-analysis", "python"],
      "preferredSkills": ["visualization"],
      "maxLatency": 5000,
      "excludeAgents": ["slow_agent"]
    }
  }
}
```

**Response:**
```json
{
  "agent": "data_analyst",
  "confidence": 0.92,
  "matchedSkills": ["data-analysis", "python"],
  "reason": "Best match for data analysis with Python support",
  "alternates": [
    {"agent": "business_intel", "confidence": 0.78}
  ]
}
```

---

## Phase 3 – Multi-Protocol & Tooling Support

**Story:** *"I want to add support for new protocols or integrate custom tool providers without modifying SuperX core code."*

**Goal**: Enable protocol extensibility and tool integration through plugin architecture.

| Task | Status | Description |
|------|--------|-----------|
| MCP Protocol Support | 📋 Planned | Full MCP v2024-11-05 implementation |
| MCP HTTP Transport | 📋 Planned | Streamable HTTP and SSE for remote servers |
| MCP STDIO Transport | 📋 Planned | Local MCP server processes |
| MCP Docker Transport | 📋 Planned | Containerized MCP servers |
| MCP Session Management | 📋 Planned | Stateful GenServer per MCP connection |
| Protocol plugin system | 📋 Planned | Support for custom protocol adapters |
| Tool provider abstraction | 📋 Planned | Pluggable tool/resource providers |
| Agent SDK | 📋 Planned | Helper library for building A2A agents |
| Custom transport support | 📋 Planned | Support for additional transports |

### MCP Integration Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         SuperX Gateway                          │
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐ │
│  │ A2A Agents  │◄──►│   Router    │◄──►│   MCP Client Pool   │ │
│  └─────────────┘    └─────────────┘    └──────────┬──────────┘ │
│                                                    │            │
└────────────────────────────────────────────────────┼────────────┘
                                                     │
                    ┌────────────────────────────────┼────────────────────────────────┐
                    │                                │                                │
                    ▼                                ▼                                ▼
           ┌───────────────┐              ┌───────────────┐              ┌───────────────┐
           │  MCP Server   │              │  MCP Server   │              │  MCP Server   │
           │  (Database)   │              │  (Filesystem) │              │  (Web APIs)   │
           └───────────────┘              └───────────────┘              └───────────────┘
```

### Protocol Extension Points

| Extension Point | Description |
|----------------|-------------|
| **Protocol Adapters** | Implement custom wire protocols (gRPC, WebSocket, etc.) |
| **Transport Plugins** | Custom communication mechanisms |
| **Message Transformers** | Protocol translation and adaptation |
| **Agent SDKs** | Helper libraries for building compatible agents |

---

## Phase 4 – Observability & Monitoring

**Story:** *"When something goes wrong, I need to know immediately. I want dashboards showing agent health, request latency, and error rates – without building custom monitoring."*

**Goal**: Production-grade observability.

| Task | Status | Description |
|------|--------|-------------|
| Prometheus metrics | 📋 Planned | Request latency, throughput, errors |
| Distributed tracing | 📋 Planned | OpenTelemetry integration |
| Dashboard templates | 📋 Planned | Grafana dashboards for monitoring |
| Alerting rules | 📋 Planned | Pre-configured alert definitions |

---

## Phase 5 – Enterprise Features

**Story:** *"We have multiple teams using SuperX. Each team needs their own agents, rate limits, and audit logs – isolated from other teams but managed centrally."*

**Goal**: Enterprise-ready deployment options.

| Task | Status | Description |
|------|--------|-------------|
| Rate limiting | 📋 Planned | Per-client and per-agent limits |
| Authentication | 📋 Planned | API key and OAuth2 support |
| Audit logging | 📋 Planned | Comprehensive request/response logging |
| Multi-tenancy | 📋 Planned | Isolated agent pools per tenant |

---

## Phase 6 – Advanced Observability & Monitoring

**Story:** *"When something goes wrong, I need to know immediately. I want dashboards showing agent health, request latency, and error rates – without building custom monitoring."*

**Goal**: Production-grade observability.

| Task | Status | Description |
|------|--------|-------------|
| Prometheus metrics | 📋 Planned | Request latency, throughput, errors |
| Distributed tracing | 📋 Planned | OpenTelemetry integration |
| Dashboard templates | 📋 Planned | Grafana dashboards for monitoring |
| Alerting rules | 📋 Planned | Pre-configured alert definitions |

---

## Phase 5 – Observability & Monitoring

**Story:** *"When something goes wrong, I need to know immediately. I want dashboards showing agent health, request latency, and error rates – without building custom monitoring."*

**Goal**: Production-grade observability.

| Task | Status | Description |
|------|--------|-------------|
| Prometheus metrics | 📋 Planned | Request latency, throughput, errors |
| Distributed tracing | 📋 Planned | OpenTelemetry integration |
| Dashboard templates | 📋 Planned | Grafana dashboards for monitoring |
| Alerting rules | 📋 Planned | Pre-configured alert definitions |

---

## Phase 5 – Enterprise Features

**Story:** *"We have multiple teams using SuperX. Each team needs their own agents, rate limits, and audit logs – isolated from other teams but managed centrally."*

**Goal**: Enterprise-ready deployment options.

| Task | Status | Description |
|------|--------|-------------|
| Rate limiting | 📋 Planned | Per-client and per-agent limits |
| Authentication | 📋 Planned | API key and OAuth2 support |
| Audit logging | 📋 Planned | Comprehensive request/response logging |
| Multi-tenancy | 📋 Planned | Isolated agent pools per tenant |

---

## Phase 5 – Observability & Monitoring

**Story:** *"When something goes wrong, I need to know immediately. I want dashboards showing agent health, request latency, and error rates – without building custom monitoring."*

**Goal**: Production-grade observability.

| Task | Status | Description |
|------|--------|-------------|
| Prometheus metrics | 📋 Planned | Request latency, throughput, errors |
| Distributed tracing | 📋 Planned | OpenTelemetry integration |
| Dashboard templates | 📋 Planned | Grafana dashboards for monitoring |
| Alerting rules | 📋 Planned | Pre-configured alert definitions |

---

## Phase 5 – Enterprise Features

**Story:** *"We have multiple teams using SuperX. Each team needs their own agents, rate limits, and audit logs – isolated from other teams but managed centrally."*

**Goal**: Enterprise-ready deployment options.

| Task | Status | Description |
|------|--------|-------------|
| Rate limiting | 📋 Planned | Per-client and per-agent limits |
| Authentication | 📋 Planned | API key and OAuth2 support |
| Audit logging | 📋 Planned | Comprehensive request/response logging |
| Multi-tenancy | 📋 Planned | Isolated agent pools per tenant |

---

## Contributing

We welcome contributions! See [CONTRIBUTING.md](../CONTRIBUTING.md) for guidelines.

Priority areas:
1. **Smart routing** - Skill-based agent selection
2. **Observability** - Metrics and tracing
3. **Enterprise features** - Rate limiting and multi-tenancy

---

## Legend

| Status | Meaning |
|--------|---------|
| ✅ Done | Completed and released |
| 🔄 In Progress | Currently being worked on |
| 📋 Planned | On the roadmap, not started |
| 💡 Proposed | Under consideration |
