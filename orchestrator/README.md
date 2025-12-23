# SuperX Orchestrator

The core Elixir application powering the SuperX Agentic Gateway. This document covers development setup, architecture, and contribution guidelines.

> **For deployment and user guides, see the [main README](../README.md).**

## Table of Contents

- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Architecture Overview](#architecture-overview)
- [Documentation](#documentation)
- [Quick Reference](#quick-reference)

## Development Setup

### Prerequisites

- **Elixir 1.19+** / **OTP 28+**
- **PostgreSQL 16+** (for full test suite)
- **Docker** (recommended for database)

### Getting Started

```bash
# Install dependencies
mix deps.get
mix compile

# Quick start (memory mode - no database required)
$env:SUPERX_PERSISTENCE="memory"; mix run --no-halt  # PowerShell
SUPERX_PERSISTENCE=memory mix run --no-halt          # Linux/macOS

# With PostgreSQL
docker compose -f ../docker-compose.yml up -d db
mix ecto.setup
mix run --no-halt
```

### Running Tests

```bash
# Memory mode (fast, 173 tests)
$env:SUPERX_PERSISTENCE="memory"; mix test --exclude postgres_only

# PostgreSQL mode (full suite, 210 tests)
$env:SUPERX_PERSISTENCE="postgres"; mix test

# With coverage report
mix coveralls
```

See [Testing Guide](docs/testing.md) for detailed test documentation.

### Code Quality

```bash
# Format code
mix format

# Static analysis
mix dialyzer

# All checks
mix format --check-formatted && mix dialyzer
```

## Project Structure

```
orchestrator/
├── lib/
│   └── orchestrator/
│       ├── agent/              # Agent management
│       │   ├── loader.ex       # YAML/ENV agent loading
│       │   ├── registry.ex     # Agent registry (ETS/Postgres)
│       │   ├── worker.ex       # Per-agent GenServer with circuit breaker
│       │   └── supervisor.ex   # Agent worker supervision
│       │
│       ├── task/               # Task management
│       │   ├── store.ex        # Task persistence behavior
│       │   ├── memory_store.ex # In-memory ETS implementation
│       │   └── db_store.ex     # PostgreSQL implementation
│       │
│       ├── push/               # Push notifications
│       │   ├── notifier.ex     # Async notification delivery
│       │   ├── signer.ex       # HMAC/JWT/Token signing
│       │   └── jwt.ex          # JWT generation & validation
│       │
│       ├── rpc/                # JSON-RPC handlers
│       │   ├── router.ex       # Method routing
│       │   ├── handlers/       # Method implementations
│       │   └── middleware.ex   # Request processing
│       │
│       ├── cluster/            # Distributed clustering
│       │   └── topology.ex     # libcluster configuration
│       │
│       ├── http_client.ex      # Finch HTTP client wrapper
│       ├── router.ex           # Plug router (endpoints)
│       ├── repo.ex             # Ecto repository
│       └── application.ex      # OTP application entry
│
├── priv/
│   └── db/
│       └── migrations/         # Ecto database migrations
│
├── test/
│   ├── orchestrator/           # Unit tests by module
│   ├── integration/            # Integration tests
│   └── support/                # Test helpers
│
├── config/
│   ├── config.exs              # Compile-time configuration
│   ├── dev.exs                 # Development overrides
│   ├── test.exs                # Test environment
│   ├── prod.exs                # Production settings
│   └── runtime.exs             # Runtime configuration (env vars)
│
└── docs/                       # Developer documentation
    ├── api.md                  # Complete API reference
    ├── architecture.md         # System architecture
    ├── configuration.md        # Environment variables
    ├── testing.md              # Test guide
    └── deployment.md           # Deployment guide
```

## Architecture Overview

### Supervision Tree

```
Orchestrator.Application
├── Orchestrator.Repo (PostgreSQL connection pool)
├── Orchestrator.TaskStore.Supervisor
│   └── Orchestrator.TaskStore (ETS or DB-backed)
├── Orchestrator.Agent.Supervisor
│   ├── Orchestrator.Agent.Registry
│   └── Orchestrator.Agent.WorkerSupervisor
│       ├── Agent.Worker (agent_1)
│       ├── Agent.Worker (agent_2)
│       └── ...
├── Orchestrator.Push.Notifier
├── Orchestrator.HttpClient (Finch pool)
├── Orchestrator.Cluster.Topology (libcluster)
└── Bandit (HTTP server)
```

### Key Design Patterns

| Pattern | Implementation | Purpose |
|---------|---------------|---------|
| **Circuit Breaker** | `Agent.Worker` | Prevent cascade failures to unhealthy agents |
| **Backpressure** | `Agent.Worker` | Limit concurrent requests per agent |
| **Behavior Pattern** | `TaskStore`, `AgentRegistry` | Swap memory/postgres implementations |
| **Registry** | `Agent.Registry` | Track agents and their workers |
| **Supervisor** | Throughout | Fault tolerance via OTP supervision |

### Request Flow

```
HTTP Request → Router → RPC.Router → Handler → Agent.Worker → Remote Agent
     ↓                                              ↓
  Response  ←──────────────────────────────────────┘
     ↓
Push.Notifier → Webhook (async)
```

## Documentation

| Document | Description |
|----------|-------------|
| [API Reference](docs/api.md) | Complete JSON-RPC API with examples |
| [Architecture](docs/architecture.md) | Detailed system design |
| [Configuration](docs/configuration.md) | All environment variables |
| [Testing Guide](docs/testing.md) | Running and writing tests |
| [Deployment](docs/deployment.md) | Production deployment guide |

## Quick Reference

### Essential Commands

```bash
# Development
mix deps.get                  # Install dependencies
mix compile                   # Compile project
mix run --no-halt             # Start server
iex -S mix                    # Interactive shell

# Database
mix ecto.create               # Create database
mix ecto.migrate              # Run migrations
mix ecto.reset                # Drop + create + migrate

# Testing
mix test                      # Run tests
mix test --only integration   # Integration tests only
mix coveralls                 # Coverage report

# Production
mix release                   # Build release
mix phx.digest                # Compile assets
```

### Key Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 4000 | HTTP server port |
| `SUPERX_PERSISTENCE` | postgres | `postgres` or `memory` |
| `AGENTS_FILE` | — | Path to agents YAML |
| `DATABASE_URL` | — | PostgreSQL connection |

See [Configuration Guide](docs/configuration.md) for complete list.

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
- Tag postgres-only tests with `@moduletag :postgres_only`

## License

MIT License - see [LICENSE](../LICENSE) for details.

