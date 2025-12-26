# SuperX - Agentic Gateway Orchestrator

<p align="center">
  <strong>Open-source infrastructure for multi-agent systems at scale</strong>
</p>

<p align="center">
  <a href="#when-do-you-need-superx">When to Use</a> •
  <a href="#the-gap-superx-fills">Why SuperX</a> •
  <a href="#features">Features</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#documentation">Documentation</a>
</p>

---

## 🚀 Introducing SuperX (v0.1.0-alpha)

Agentic frameworks like Google ADK, LangGraph, and AutoGen already help developers design complex agent workflows, manage sessions, and add observability. They make it much easier to build and reason about multi-agent systems *within a given stack*.

But as systems scale, teams often need a **shared infrastructure layer** that sits *between* agents — especially when agents are built using different frameworks, deployed independently, or scaled separately.

Google's [A2A Protocol](https://github.com/google/A2A) defines common standards for how agents communicate and exchange context. But **protocols alone don't handle runtime concerns**: routing, backpressure, resilience, persistence, or real-time coordination.

**That's the gap SuperX is exploring.**

## When Do You Need SuperX?

You're a good fit for SuperX if:

- ✅ You have **multiple AI agents** (2+) that need to work together
- ✅ Agents are **built with different frameworks** (LangGraph, AutoGen, custom, etc.)
- ✅ Agents are **deployed independently** or scaled separately
- ✅ You need **real-time visibility** into agent workflows and failures
- ✅ You want **resilience built-in** — circuit breakers, backpressure, task persistence
- ✅ You need **dynamic routing** — not hardcoded which agent handles what

If you're managing a single agent or all agents are tightly coupled within one framework, you don't need SuperX yet.

## The Gap SuperX Fills

```
                    Agent Frameworks              Protocols              Infrastructure
                    ─────────────────             ─────────              ──────────────
                    
                    ✅ LangGraph                  ✅ A2A Protocol        ❓ Routing
                    ✅ AutoGen                    ✅ Standards           ❓ Load Balancing
                    ✅ Google ADK                                        ❓ Backpressure
                    ✅ Custom                                            ❓ Circuit Breakers
                                                                         ❓ Task Persistence
                                                                         ❓ Multi-Agent Coordination
                                                                         
                                           SuperX fills this gap ↑
```

SuperX acts as an **agentic gateway and orchestrator**, handling infrastructure concerns outside the agent logic itself:

- **Intelligent routing** — Route messages to agents based on skills, availability, and load
- **Real-time streaming** — Observe agent progress as it happens via Server-Sent Events
- **Built-in resilience** — Circuit breakers, backpressure, and graceful degradation
- **Task persistence** — Track multi-turn conversations and handle failures
- **Dynamic agent registry** — Register/deregister agents without restarting
- **A2A Protocol support** — Full support for Google's Agent-to-Agent protocol

If AI agents are like **specialized employees**, SuperX is the **shared infrastructure** — routing conversations, managing failures, and keeping work moving when parts of the system slow down or fail.

## The Solution

```
┌─────────────┐      ┌─────────────────────────────────────┐      ┌─────────────┐
│             │      │            SUPERX                   │      │   Agent A   │
│   Your App  │ ───► │  • Routing      • Load Balancing   │ ───► │   Agent B   │
│             │      │  • Failover     • Monitoring       │      │   Agent C   │
└─────────────┘      └─────────────────────────────────────┘      └─────────────┘
                              One endpoint.                        Many agents.
                              Any protocol.                        Hidden complexity.
```

| Concern | Manual | With SuperX |
|---------|--------|------------|
| Adding a new agent | Update all client code | Register once, available everywhere |
| Agent goes down | Client apps fail | Automatic failover with circuit breaker |
| Which agent to use? | Hardcoded in client | Smart routing based on skills/load |
| Multi-turn conversations | Manage state yourself | Task manager handles it |
| Agent overload | Manual backpressure logic | Built-in per-agent concurrency limits |
| Monitor health | Build custom dashboards | Observability-first design (Phase 4+) |

## Features

### Infrastructure Concerns Handled

| Feature | Why It Matters |
|---------|----------------|
| **Intelligent Routing** | Route messages based on agent skills and load, not hardcoded endpoints |
| **Real-Time Streaming** | Watch agent work in progress via Server-Sent Events (SSE) |
| **Task Management** | Persist multi-turn conversations; resume after agent failures |
| **Circuit Breaker** | Detect failing agents, fail fast, recover gracefully |
| **Backpressure** | Per-agent concurrency limits prevent cascade failures |
| **Dynamic Registry** | Register/deregister agents at runtime without restarts |
| **A2A Protocol** | Full support for Google's Agent-to-Agent protocol |
| **Per-Request Webhooks** | Ephemeral notifications without pre-configuration |
| **Push Notifications** | Webhook-based notifications with HMAC, JWT, or token auth |
| **Horizontal Scaling** | Distribute across Erlang nodes, no external database required |
| **Clustering** | Auto-discovery via gossip, DNS, or Kubernetes |

## Quick Start

### Using Docker Compose (Recommended)

```bash
# Clone the repository
git clone https://github.com/alfinjohnson/superx.git
cd superx

# Start PostgreSQL and the orchestrator
docker compose up -d

# Check health
curl http://localhost:4000/health

# View logs
docker compose logs -f orchestrator
```

### Development Mode

```bash
cd orchestrator
mix deps.get
mix compile

# Start PostgreSQL (if not running)
docker compose up -d postgres

# Run database migrations
mix ecto.setup

# Start the server
mix run --no-halt
```

### Configure Agents

SuperX loads agents from a YAML configuration file. Create or modify `agents.yml`:

```yaml
# samples/agents.yml
agents:
  # A2A Protocol Agent
  my_agent:
    url: http://localhost:8001/a2a/my_agent      # A2A RPC endpoint of your agent
    bearer: ""  # Optional: API token for authentication
    protocol: a2a
    protocolVersion: 0.3.0
    metadata:
      agentCard:
        url: http://localhost:8001/a2a/my_agent/.well-known/agent-card.json
        name: my_agent
        description: Description of what this agent does
        skills:
          - id: skill_id
            name: Skill Name
            description: What this skill does

  # Another A2A Agent
  assistant_agent:
    url: http://localhost:8002/a2a/assistant
    protocol: a2a
    protocolVersion: 0.3.0
    metadata:
      agentCard:
        url: http://localhost:8002/a2a/assistant/.well-known/agent-card.json
        name: assistant_agent
        description: General purpose assistant agent
```

**URL Configuration:**
- `url`: The A2A JSON-RPC endpoint of your agent server (e.g., `http://host:port/a2a/agent_name`)
- `agentCard.url`: The agent card discovery endpoint (typically `{agent_url}/.well-known/agent-card.json`)
- `bearer`: Optional authentication token for securing agent communication

> **Note:** You need an A2A-compatible agent server running at the specified URL. See the [Google A2A Python samples](https://github.com/google/A2A/tree/main/samples/python) for example implementations.

Set the `SUPERX_AGENTS_FILE` environment variable to load your agents:

```bash
# Using environment variable
$env:SUPERX_AGENTS_FILE="./samples/agents.yml"; mix run --no-halt

# Or in docker-compose.yml
environment:
  - SUPERX_AGENTS_FILE=/app/config/agents.yml
```

See [samples/agents.yml](samples/agents.yml) for a complete example.

### Per-Request Webhooks

Pass webhook URLs directly in requests for ephemeral notifications without pre-configuration:

```bash
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"message/send",
    "params":{
      "agentId":"my_agent",
      "message":{"role":"user","parts":[{"text":"Hello"}]},
      "metadata":{
        "webhook":{
          "url":"https://myapp.com/webhook",
          "hmacSecret":"secret123",
          "token":"bearer-token"
        }
      }
    }
  }'
```

**Webhook Configuration:**
- `url` (required): Endpoint to receive notifications
- `hmacSecret` (optional): Secret for HMAC-SHA256 signing
- `token` (optional): Bearer token for authentication
- `jwtClaims` (optional): Custom JWT claims

Per-request webhooks take precedence over stored webhook configurations.

### Verify Installation

```bash
# List registered agents
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"agents/list","params":{}}'

# Send a message to an agent
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"message/send",
    "params":{
      "agent":"check_prime_agent",
      "message":{"role":"user","parts":[{"text":"Is 17 a prime number?"}]}
    }
  }'
```

## Architecture

```
                              ┌─────────────────────────────────────────┐
                              │            SuperX Gateway               │
                              │                                         │
┌──────────┐                  │  ┌─────────────────────────────────┐   │
│  Client  │ ──── A2A ────────┼─▶│        Router & Load Balancer   │   │
└──────────┘    Protocol      │  └────────────────┬────────────────┘   │
                              │                   │                     │
                              │    ┌──────────────┼──────────────┐     │
                              │    │              │              │     │
                              │    ▼              ▼              ▼     │
                              │ ┌──────┐     ┌──────┐     ┌──────┐    │
                              │ │Agent │     │Agent │     │Agent │    │
                              │ │Worker│     │Worker│     │Worker│    │
                              │ └──┬───┘     └──┬───┘     └──┬───┘    │
                              │    │            │            │        │
                              │    │ Circuit    │ Circuit    │ Circuit│
                              │    │ Breaker    │ Breaker    │ Breaker│
                              └────┼────────────┼────────────┼────────┘
                                   │            │            │
                                   ▼            ▼            ▼
                              ┌──────────┐ ┌──────────┐ ┌──────────┐
                              │ Agent A  │ │ Agent B  │ │ Agent C  │
                              │ (Remote) │ │ (Remote) │ │ (Remote) │
                              └──────────┘ └──────────┘ └──────────┘
```

### Key Components

- **Router**: Receives A2A protocol requests and routes to appropriate agents
- **Agent Workers**: Manage per-agent state, circuit breakers, and backpressure
- **Task Manager**: Persists task state and handles multi-turn conversations
- **Push Notifier**: Delivers webhook notifications with configurable security

## Deployment

### Storage

SuperX uses a **hybrid PostgreSQL + ETS caching** architecture for durability with fast reads.

| Aspect | Details |
|--------|--------|
| **Write-Through Cache** | All writes go to PostgreSQL first, then ETS cache |
| **Sub-Millisecond Reads** | ETS cache provides ~0.5ms read latency |
| **Durable Storage** | PostgreSQL ensures data survives restarts |
| **Automatic Cache Warming** | Cache populated from database on startup |
| **Distributed Ready** | Horde for distributed registry and supervisor |

> **Note:** PostgreSQL is required for production deployments. The ETS cache provides fast reads while PostgreSQL ensures durability.

### Docker

```bash
# Production mode
docker compose up orchestrator

# Development mode with hot reload
docker compose up orchestrator-dev
```

### Environment Configuration

Key environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 4000 | HTTP server port |
| `DATABASE_URL` | — | PostgreSQL connection URL |
| `AGENTS_FILE` | — | Path to agents YAML configuration |
| `CLUSTER_STRATEGY` | — | Clustering: `gossip`, `dns`, `kubernetes` |
| `SECRET_KEY_BASE` | — | Secret key for cryptographic operations (required in prod) |

### Production Deployment

```bash
# Set required environment variables
export PORT=4000
export DATABASE_URL=ecto://user:pass@host/superx_prod
export AGENTS_FILE=/etc/superx/agents.yml
export SECRET_KEY_BASE=$(openssl rand -base64 64)

# Pull and run
docker pull ghcr.io/anthropics/superx:latest
docker run -d \
  --name superx \
  -p 4000:4000 \
  -e PORT \
  -e DATABASE_URL \
  -e AGENTS_FILE \
  -e SECRET_KEY_BASE \
  -v /etc/superx/agents.yml:/home/app/agents.yml:ro \
  ghcr.io/anthropics/superx:latest
```

## Agent Configuration

Agents can be configured via YAML file or runtime API.

### YAML Configuration

Create an `agents.yml` file:

```yaml
agents:
  - name: my_agent
    url: https://agent.example.com/.well-known/agent.json
    # Optional: bearer token for authenticated agents
    bearer: "your-bearer-token"
```

Mount the file and set `AGENTS_FILE`:

```bash
docker run -d \
  -v ./agents.yml:/home/app/agents.yml:ro \
  -e AGENTS_FILE=/home/app/agents.yml \
  -e DATABASE_URL=ecto://user:pass@host/superx \
  ghcr.io/anthropics/superx:latest
```

### Runtime Agent Management

```bash
# Register an agent
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"agents/upsert",
    "params":{
      "name":"my_agent",
      "url":"https://agent.example.com/.well-known/agent.json"
    }
  }'

# Check agent health
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"agents/health","params":{"name":"my_agent"}}'

# Refresh agent card
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"agents/refreshCard","params":{"name":"my_agent"}}'
```

## Project Structure

```
superx/
├── orchestrator/           # Main Elixir application
│   ├── lib/               # Source code
│   │   └── orchestrator/  # Core modules
│   │       ├── agent/     # Agent management (Store with ETS+PostgreSQL)
│   │       ├── task/      # Task management (Store, PubSub, Streaming)
│   │       ├── schema/    # Ecto schemas (Task, Agent, PushConfig)
│   │       ├── protocol/  # Protocol implementations
│   │       │   └── a2a/   # A2A protocol (Adapter, Proxy, PushNotifier)
│   │       └── web/       # Web layer (Router, Streaming, Handlers)
│   ├── priv/db/           # Database migrations
│   └── test/              # Test suite (430+ tests)
│       ├── protocol/      # Protocol-specific tests
│       └── stress/        # Stress and performance tests
├── docs/                  # Documentation
│   ├── a2a-v030/         # A2A v0.3.0 specification
│   └── roadmap.md        # Development roadmap
├── samples/              # Sample configurations
│   └── agents.yml        # Example agent configuration
└── docker-compose.yml    # Local development setup
```

## Documentation

### User Guides

- **[Quick Start](#quick-start)** - Get running in minutes
- **[Architecture](#architecture)** - System design overview
- **[Deployment](#deployment)** - Production deployment guide
- **[Roadmap](docs/roadmap.md)** - Future development plans

### Developer Documentation

- **[Orchestrator README](orchestrator/README.md)** - Development setup and contribution guide
- **[CHANGELOG](CHANGELOG.md)** - Version history and changes
- **[CONTRIBUTING](CONTRIBUTING.md)** - Contribution guidelines

### Protocol Specification

- **[A2A Protocol](https://github.com/google/A2A)** — Google's Agent-to-Agent protocol specification
- **[A2A Documentation](https://google.github.io/A2A/)** — Official protocol documentation
- **[A2A Python Samples](https://github.com/google/A2A/tree/main/samples/python)** — Example agent implementations
- **[A2A v0.3.0 Spec](docs/a2a-v030/specification.md)** — Local copy of A2A specification

## Tech Stack

Built with **Elixir and OTP** — designed for exactly what we need: long-running, fault-tolerant, highly concurrent agent workflows. Reliability is a first-class concern, not an afterthought.

| Component | Technology |
|-----------|------------|
| **Runtime** | Elixir 1.19+ / OTP 28+ (lightweight, concurrent, distributed) |
| **Database** | PostgreSQL 15+ with Ecto (durable storage) |
| **Caching** | ETS (sub-millisecond reads, write-through cache) |
| **HTTP Server** | Bandit (fast, Plug-compatible, streaming support) |
| **Distributed State** | Horde (distributed registry, supervisor) |
| **Clustering** | libcluster (gossip, DNS, Kubernetes) |
| **Container** | Docker (multi-stage build) |
| **Testing** | ExUnit (430+ tests, high coverage) |

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Run tests (`mix test --exclude stress`)
4. Commit changes (`git commit -m 'Add amazing feature'`)
5. Push to branch (`git push origin feature/amazing-feature`)
6. Open a Pull Request

## License

MIT License - see [LICENSE](LICENSE) for details.
