# SuperX Roadmap

Strategic roadmap for SuperX Agentic Gateway Orchestrator development.

---

## Current State ✅

SuperX is a production-ready A2A Protocol gateway with:
- Full A2A v0.3.0 protocol implementation
- OTP-distributed task management via Horde (hybrid mode)
- Per-request webhooks for real-time notifications
- Circuit breaker and backpressure patterns
- Push notifications with HMAC/JWT/Token auth
- Erlang clustering support (gossip, DNS, Kubernetes)
- 180+ tests with comprehensive coverage

---

## Feature 0 – Hybrid Task Management (In Progress)

**Goal**: OTP-powered distributed task management without external dependencies.

| Task | Status | Description |
|------|--------|-------------|
| Horde-based task registry | 🔄 In Progress | Distributed in-memory task storage via OTP |
| Per-request webhooks | ✅ Done | Webhook URLs provided per request, delivered immediately |
| Distributed task.get/subscribe | 🔄 In Progress | Query tasks from Horde cluster (no DB needed) |
| Task lifecycle management | 🔄 Planned | Active task tracking, completion archival |
| Optional Postgres persistence | 📋 Planned | Archive completed tasks for audit/history (future) |
| Documentation update | 🔄 In Progress | Hybrid mode architecture and usage guide |

### Hybrid Mode Benefits

- **Zero external dependencies** - Pure OTP, no required database
- **Automatic distribution** - Tasks replicated across cluster
- **Low latency** - In-memory access, no DB queries
- **All APIs work** - `tasks.get`, `tasks.subscribe`, `message.send`, `message.stream`
- **Future-proof** - Postgres support can be added without breaking changes
- **Scalable** - Horizontal scaling built-in via Horde

---

## Feature 1 – Smart Routing

**Goal**: Intelligent agent selection based on capabilities.

### `superx/route` Method

```json
{
  "method": "superx/route",
  "params": {
    "capability": "code-review",
    "message": {"role": "user", "parts": [{"text": "Review this PR"}]},
    "strategy": "best-match"
  }
}
```

### Features

| Feature | Description |
|---------|-------------|
| Capability matching | Select agents by skills from agent card |
| Health-aware routing | Avoid agents with open circuit breakers |
| Load balancing | Round-robin among matching healthy agents |
| Fallback strategies | Configurable behavior when no match found |

---

## Feature 2 – Fan-out Orchestration

**Goal**: Parallel execution across multiple agents.

### `superx/fanout` Method

```json
{
  "method": "superx/fanout",
  "params": {
    "agents": ["agent_a", "agent_b", "agent_c"],
    "message": {"role": "user", "parts": [{"text": "Analyze this data"}]},
    "strategy": "all"
  }
}
```

### Strategies

| Strategy | Description |
|----------|-------------|
| `all` | Wait for all agents, aggregate responses |
| `race` | Return first successful response |
| `consensus` | Return when majority agree |
| `quorum` | Return when N agents respond |

### Response Aggregation

- Combine into single A2A-compatible Task response
- Include metadata about which agents responded
- Error handling for partial failures

---

## Feature 3 – Pipelines

**Goal**: Chain agents for multi-step workflows.

### `superx/pipeline` Method

```json
{
  "method": "superx/pipeline",
  "params": {
    "stages": [
      {"agent": "researcher", "timeout": 30000},
      {"agent": "analyzer", "input": "{{previous.parts[0].text}}"},
      {"agent": "summarizer"}
    ],
    "message": {"role": "user", "parts": [{"text": "Research AI trends"}]}
  }
}
```

### Features

| Feature | Description |
|---------|-------------|
| Stage chaining | Output of stage N feeds into stage N+1 |
| Templating | Simple variable substitution for inputs |
| Timeout controls | Per-stage and total pipeline timeouts |
| Abort handling | Stop pipeline on stage failure (configurable) |
| Parallel stages | Run independent stages concurrently |

---

## Feature 4 – Operational Hardening

**Goal**: Production-grade observability and controls.

### Telemetry & Metrics

| Metric | Description |
|--------|-------------|
| `superx.route.duration` | Routing decision time |
| `superx.fanout.duration` | Fan-out total time |
| `superx.pipeline.stage.duration` | Per-stage timing |
| `superx.agent.selection` | Agent selection events |

### Rate Limiting

- Token-scoped quotas (stateless)
- Per-tenant rate limits
- Configurable via headers or JWT claims

### Observability

- Structured JSON logging
- Correlation IDs across requests
- Distributed tracing (OpenTelemetry)
- Health dashboard endpoints

### Optional Storage

- Postgres adapter for completed task archival (planned)
- Plug-in architecture for custom storage backends
- Redis adapter for high-performance caching (future)
- S3/blob storage for artifact persistence (future)

---

## Feature 5 – Developer Experience

**Goal**: Make SuperX easy to adopt and operate.

### CLI Tools

```bash
# Validate agents.yml
superx validate agents.yml

# Test agent connectivity
superx ping my_agent

# Generate agent card template
superx init-card
```

### Deployment Templates

- Kubernetes manifests (Helm chart)
- Docker Compose examples
- Terraform modules
- Cloud Run / ECS / Lambda examples

### Documentation & Examples

- Postman collection
- HTTPie recipes
- SDK examples (Python, TypeScript, Go)
- Video tutorials

---

## Principles

### A2A Compatibility First

Standard A2A methods remain unchanged. Extensions live under `superx/*` namespace:

| Standard Methods | SuperX Extensions |
|-----------------|-------------------|
| `message/send` | `superx/route` |
| `message/stream` | `superx/fanout` |
| `tasks/get` | `superx/pipeline` |
| `agents/list` | `superx/health` |

### Stateless by Default

- OTP-managed distributed state via Horde
- No required external dependencies (pure Erlang clustering)
- Easy horizontal scaling with automatic task replication
- Optional Postgres persistence for audit trail (future)
- Per-request webhooks for immediate notification delivery

### Backward Safe

- Extensions are purely additive
- Existing behavior never changes
- Version negotiation for new features
- Graceful degradation

---

## Contributing

We welcome contributions! Priority areas:

1. **Smart Routing** - Help implement capability matching
2. **Fan-out Strategies** - Implement consensus/quorum algorithms
3. **SDK Development** - Python, TypeScript, Go clients
4. **Documentation** - Tutorials, examples, translations

See [Contributing Guide](../CONTRIBUTING.md) for details.
