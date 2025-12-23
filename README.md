# SuperX - Agentic Gateway Orchestrator

<p align="center">
  <strong>A high-performance gateway + orchestrator for AI agents with support for the A2A Protocol and more</strong>
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#deployment">Deployment</a> •
  <a href="#documentation">Documentation</a>
</p>

---

SuperX is an **experimental Agentic Gateway Orchestrator** that helps AI agents connect and communicate through a unified gateway. Currently supporting the [Agent-to-Agent (A2A) Protocol](https://github.com/google/A2A), with plans to add support for additional protocols in the future. It serves as a central hub for routing messages between AI agents, managing their lifecycles, and maintaining state across conversations.

## Features

| Feature | Description |
|---------|-------------|
| **A2A Protocol Support** | Full support for Google's Agent-to-Agent protocol (more protocols coming soon) |
| **Intelligent Routing** | Route messages to agents based on skills, availability, and load |
| **Task Management** | Create, track, and manage tasks with full state persistence |
| **Streaming** | Real-time message streaming via Server-Sent Events (SSE) |
| **Push Notifications** | Webhook-based notifications with HMAC, JWT, or token auth |
| **Agent Registry** | Dynamic agent registration and discovery |
| **Circuit Breaker** | Automatic failure detection with configurable thresholds |
| **Backpressure** | Per-agent concurrency limits prevent overload |
| **Horizontal Scaling** | PostgreSQL-backed shared state for multi-node deployments |
| **Clustering** | Erlang node clustering via gossip, DNS, or Kubernetes |

## Quick Start

### Using Docker Compose (Recommended)

```bash
# Clone the repository
git clone https://github.com/your-org/superx.git
cd superx

# Start with PostgreSQL (production mode)
docker compose up -d

# Check health
curl http://localhost:4000/health

# View logs
docker compose logs -f orchestrator
```

### Development Mode (In-Memory)

```bash
cd orchestrator
mix deps.get
mix compile

# Run with in-memory storage (no database required)
$env:SUPERX_PERSISTENCE="memory"; mix run --no-halt
```

### Configure Agents

SuperX loads agents from a YAML configuration file. Create or modify `agents.yml`:

```yaml
# samples/agents.yml
agents:
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
```

**URL Configuration:**
- `url`: The A2A JSON-RPC endpoint of your agent server (e.g., `http://host:port/a2a/agent_name`)
- `agentCard.url`: The agent card discovery endpoint (typically `{agent_url}/.well-known/agent-card.json`)

> **Note:** You need an A2A-compatible agent server running at the specified URL. See the [Google A2A Python samples](https://github.com/google/A2A/tree/main/samples/python) to learn how to build an agent.

Set the `SUPERX_AGENTS_FILE` environment variable to load your agents:

```bash
# Using environment variable
$env:SUPERX_AGENTS_FILE="./samples/agents.yml"; mix run --no-halt

# Or in docker-compose.yml
environment:
  - SUPERX_AGENTS_FILE=/app/config/agents.yml
```

See [samples/agents.yml](samples/agents.yml) for a complete example.

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

### Persistence Modes

| Mode | Use Case | Data Durability |
|------|----------|-----------------|
| **PostgreSQL** (default) | Production, multi-node | Persistent |
| **Memory** | Development, testing, edge | Ephemeral |

### Docker Compose Services

```bash
# Production mode with PostgreSQL
docker compose up orchestrator

# Development mode with hot reload
docker compose up orchestrator-dev

# Stateless mode (in-memory, single node)
docker compose up orchestrator-stateless
```

### Environment Configuration

Key environment variables (see [Configuration Guide](orchestrator/docs/configuration.md) for complete list):

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 4000 | HTTP server port |
| `SUPERX_PERSISTENCE` | postgres | Storage mode: `postgres` or `memory` |
| `DATABASE_URL` | — | PostgreSQL connection string |
| `AGENTS_FILE` | — | Path to agents YAML configuration |
| `CLUSTER_STRATEGY` | — | Clustering: `gossip`, `dns`, `kubernetes` |

### Production Deployment

```bash
# Set required environment variables
export DATABASE_URL="ecto://user:pass@db.example.com/superx_prod"
export PORT=4000
export AGENTS_FILE=/etc/superx/agents.yml
export SECRET_KEY_BASE=$(openssl rand -base64 64)

# Pull and run
docker pull your-registry/superx:latest
docker run -d \
  --name superx \
  -p 4000:4000 \
  -e DATABASE_URL \
  -e PORT \
  -e AGENTS_FILE \
  -e SECRET_KEY_BASE \
  -v /etc/superx/agents.yml:/home/app/agents.yml:ro \
  your-registry/superx:latest
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
  your-registry/superx:latest
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
│   ├── test/              # Test suite (210 tests)
│   ├── priv/              # Migrations and static assets
│   └── docs/              # Developer documentation
├── docs/                  # Project documentation
│   └── roadmap.md        # Development roadmap
├── samples/              # Sample configurations
│   └── agents.yml        # Example agent configuration
├── Dockerfile            # Production container build
└── docker-compose.yml    # Local development setup
```

## Documentation

### User Guides

- **[Quick Start](#quick-start)** - Get running in minutes
- **[Architecture](#architecture)** - System design overview
- **[Deployment](#deployment)** - Production deployment guide
- **[Roadmap](docs/roadmap.md)** - Future development plans

### Developer Documentation

- **[Orchestrator README](orchestrator/README.md)** - Development setup and architecture
- **[API Reference](orchestrator/docs/api.md)** - Complete RPC API documentation
- **[Configuration](orchestrator/docs/configuration.md)** - All environment variables
- **[Testing Guide](orchestrator/docs/testing.md)** - Running and writing tests
- **[Deployment Guide](orchestrator/docs/deployment.md)** - Production deployment

### Protocol Specification

- **[A2A Protocol](https://github.com/google/A2A)** - Google's Agent-to-Agent protocol specification
- **[A2A Documentation](https://google.github.io/A2A/)** - Official protocol documentation
- **[A2A Python Samples](https://github.com/google/A2A/tree/main/samples/python)** - Example agent implementations

## Tech Stack

| Component | Technology |
|-----------|------------|
| **Runtime** | Elixir 1.19 / OTP 28 |
| **Database** | PostgreSQL 16 |
| **HTTP Server** | Bandit |
| **Clustering** | libcluster |
| **Container** | Docker (multi-stage build) |

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Run tests (`mix test`)
4. Commit changes (`git commit -m 'Add amazing feature'`)
5. Push to branch (`git push origin feature/amazing-feature`)
6. Open a Pull Request

## License

MIT License - see [LICENSE](LICENSE) for details.
