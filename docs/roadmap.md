# SuperX Roadmap

Strategic roadmap for SuperX Agentic Gateway Orchestrator development.

---

## Current State ✅

SuperX is a production-ready A2A Protocol gateway with:
- Full A2A v0.3.0 protocol implementation
- Dual persistence modes (PostgreSQL / Memory)
- Circuit breaker and backpressure patterns
- Push notifications with HMAC/JWT/Token auth
- Erlang clustering support (gossip, DNS, Kubernetes)
- 210 tests with comprehensive coverage

---

## Feature 0 – Stateless Core (In Progress)

**Goal**: Make SuperX stateless by default for easy horizontal scaling.

| Task | Status | Description |
|------|--------|-------------|
| Memory persistence mode | ✅ Done | No DB dependency for stateless deployments |
| Agent configs from YAML/env | ✅ Done | GitOps-friendly configuration via `AGENTS_FILE` |
| Tasks pass-through | 🔄 Planned | Clients own task history; SuperX routes only |
| Per-request webhooks | 🔄 Planned | Webhook URLs provided per request, not stored |
| Circuit breaker in ETS | ✅ Done | Per-node resilience state |
| Documentation update | ✅ Done | Production-grade docs complete |

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

- Plug-in architecture for history storage
- PostgreSQL adapter (existing)
- Redis adapter (planned)
- S3/blob storage for artifacts

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

- No required external dependencies
- Easy horizontal scaling
- Storage is optional and pluggable
- State can be externalized (Redis, Postgres)

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
