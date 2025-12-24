# SuperX Orchestrator

The core Elixir application powering the SuperX Agentic Gateway. This document covers development setup, architecture, and contribution guidelines.

> **For deployment and user guides, see the [main README](../README.md).**

## Table of Contents

- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Architecture Overview](#architecture-overview)
- [Quick Reference](#quick-reference)

## Development Setup

### Prerequisites

- **Elixir 1.19+** / **OTP 28+**
- **Docker** (optional, for containerized deployment)

### Getting Started

```bash
# Install dependencies
mix deps.get
mix compile

# Start server (in-memory storage, no database required)
mix run --no-halt
```

### Running Tests

```bash
# Run all tests (excluding stress tests)
mix test --exclude stress

# Run with coverage report
mix coveralls

# Run stress tests (takes longer)
mix test --only stress
```

### Code Quality

```bash
# Format code
mix format

# Compile with warnings as errors
mix compile --warnings-as-errors

# All checks
mix format --check-formatted && mix compile --warnings-as-errors && mix test --exclude stress
```

## Project Structure

```
orchestrator/
├── lib/
│   └── orchestrator/
│       ├── agent/              # Agent management
│       │   ├── loader.ex       # YAML/ENV agent loading
│       │   ├── registry.ex     # Horde distributed registry
│       │   ├── store.ex        # Agent config storage (ETS)
│       │   ├── worker.ex       # Per-agent GenServer with circuit breaker
│       │   └── supervisor.ex   # Horde DynamicSupervisor
│       │
│       ├── task/               # Task management
│       │   ├── store.ex        # Distributed task storage (Horde + ETS)
│       │   ├── pubsub.ex       # Task event broadcasting
│       │   └── push_config.ex  # Webhook configuration
│       │
│       ├── infra/              # Infrastructure
│       │   ├── http_client.ex  # Finch HTTP client
│       │   ├── push_notifier.ex # Webhook delivery with retry
│       │   └── sse_client.ex   # SSE streaming client
│       │
│       ├── protocol/           # Protocol handling
│       │   ├── adapters/a2a.ex # A2A v0.3.0 adapter
│       │   ├── envelope.ex     # Protocol-agnostic envelope
│       │   └── methods.ex      # Method definitions
│       │
│       ├── application.ex      # OTP Application entry
│       └── router.ex           # Plug router (endpoints)
│
├── test/
│   ├── agent/                  # Agent module tests
│   ├── task/                   # Task module tests
│   ├── infra/                  # Infrastructure tests
│   ├── integration/            # SSE streaming integration tests
│   ├── stress/                 # Stress/load tests
│   └── support/                # Test helpers
│
└── config/
    ├── config.exs              # Compile-time configuration
    ├── test.exs                # Test environment
    ├── prod.exs                # Production settings
    └── runtime.exs             # Runtime configuration (env vars)
```

## Architecture Overview

### Supervision Tree

```
Orchestrator.Application
├── Orchestrator.Task.Store (GenServer + ETS)
├── Orchestrator.Task.PushConfig.Store (GenServer + ETS)
├── Orchestrator.Agent.Store (GenServer + ETS)
├── Orchestrator.Agent.Registry (Horde.Registry)
├── Orchestrator.Agent.Supervisor (Horde.DynamicSupervisor)
│   ├── Agent.Worker (agent_1)
│   ├── Agent.Worker (agent_2)
│   └── ...
├── Orchestrator.Infra.PushNotifier (GenServer)
├── Orchestrator.Infra.HttpClient (Finch pool)
├── Orchestrator.Infra.Cluster (libcluster)
└── Bandit (HTTP server)
```

### Key Design Patterns

| Pattern | Implementation | Purpose |
|---------|---------------|---------|
| **Circuit Breaker** | `Agent.Worker` | Prevent cascade failures to unhealthy agents |
| **Backpressure** | `Agent.Worker` | Limit concurrent requests per agent |
| **Distributed Registry** | `Horde.Registry` | Track agents across cluster nodes |
| **Distributed Supervisor** | `Horde.DynamicSupervisor` | Supervise workers across cluster |
| **ETS Storage** | `Task.Store`, `Agent.Store` | Fast in-memory data access |

### Request Flow

```
HTTP Request → Router → RPC.Router → Handler → Agent.Worker → Remote Agent
     ↓                                              ↓
  Response  ←──────────────────────────────────────┘
     ↓
Push.Notifier → Webhook (async)
```

## Quick Reference

### Essential Commands

```bash
# Development
mix deps.get                  # Install dependencies
mix compile                   # Compile project
mix run --no-halt             # Start server
iex -S mix                    # Interactive shell

# Testing
mix test                      # Run tests (excludes stress by default)
mix test --exclude stress     # Explicitly exclude stress tests
mix test --only stress        # Run stress tests only
mix coveralls                 # Coverage report

# Production
mix release                   # Build release
```

### Key Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 4000 | HTTP server port |
| `AGENTS_FILE` | — | Path to agents YAML |
| `SECRET_KEY_BASE` | — | Secret for crypto ops (required in prod) |
| `LOG_LEVEL` | info | Logging level: debug, info, warning, error |
| `CLUSTER_STRATEGY` | — | Clustering: gossip, dns, kubernetes |

### API Quick Examples

```bash
# Health check
curl http://localhost:4000/health

# List agents
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"agents/list","params":{}}'

# Send message
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","id":1,"method":"message/send",
    "params":{"agent":"my_agent","message":{"role":"user","parts":[{"text":"Hello"}]}}
  }'
```

See [API Reference](docs/api.md) for complete documentation.

## Contributing

1. **Setup**: Follow [Development Setup](#development-setup)
2. **Branch**: Create feature branch from `main`
3. **Code**: Follow existing patterns and style
4. **Test**: Ensure all tests pass (`mix test`)
5. **Format**: Run `mix format`
6. **PR**: Submit pull request with clear description

### Code Style

- Follow standard Elixir conventions
- Use `mix format` before committing
- Add `@moduledoc` and `@doc` for public functions
- Tag integration tests with `@tag :integration`
- Tag stress tests with `@moduletag :stress`

## License

MIT License - see [LICENSE](../LICENSE) for details.

