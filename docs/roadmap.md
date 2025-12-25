# SuperX Roadmap

Strategic roadmap for SuperX Agentic Gateway Orchestrator development.

---

## Current State ✅

SuperX is an experimental A2A Protocol gateway with:

- Full A2A v0.3.0 protocol implementation
- OTP-distributed task management via Horde (pure in-memory)
- Per-request webhooks for real-time notifications
- Circuit breaker and backpressure patterns
- Push notifications with HMAC/JWT/Token auth
- Erlang clustering support (gossip, DNS, Kubernetes)
- 230+ tests with comprehensive coverage

---

## Phase 1 – Core Stability (Current)

**Story:** *"I want to deploy SuperX and have it just work – no database setup, no external dependencies. Start the server and go."*

**Goal**: Stable experimental gateway with zero external dependencies.

| Task | Status | Description |
|------|--------|-------------|
| Pure OTP task storage | ✅ Done | Horde-based distributed in-memory storage |
| Per-request webhooks | ✅ Done | Webhook URLs in request metadata |
| SSE streaming | ✅ Done | Real-time task updates via Server-Sent Events |
| Circuit breaker | ✅ Done | Automatic failure detection and recovery |
| Clustering support | ✅ Done | Multi-node via gossip, DNS, Kubernetes |
| Remove PostgreSQL | ✅ Done | Simplified to pure OTP architecture |

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
| Protocol plugin system | 📋 Planned | Support for custom protocol adapters |
| Tool provider abstraction | 📋 Planned | Pluggable tool/resource providers |
| Agent SDK | 📋 Planned | Helper library for building A2A agents |
| Protocol adapters | 📋 Planned | Extensible protocol architecture |
| Custom transport support | 📋 Planned | Support for non-HTTP transports |

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
1. **MCP integration** - Tool access via Model Context Protocol
2. **Smart routing** - Skill-based agent selection
3. **Observability** - Metrics and tracing

---

## Legend

| Status | Meaning |
|--------|---------|
| ✅ Done | Completed and released |
| 🔄 In Progress | Currently being worked on |
| 📋 Planned | On the roadmap, not started |
| 💡 Proposed | Under consideration |
