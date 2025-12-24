# SuperX Orchestrator

The core Elixir application powering the SuperX Agentic Gateway — infrastructure for routing, load balancing, and resilience in multi-agent systems.

> **For user guides and deployment documentation, see the [main README](../README.md).**

## Table of Contents

- [Quick Start for Developers](#quick-start-for-developers)
- [Development Setup](#development-setup)
- [Development Workflow](#development-workflow)
- [Project Structure](#project-structure)
- [Common Development Tasks](#common-development-tasks)
- [Debugging Guide](#debugging-guide)
- [Architecture Overview](#architecture-overview)
- [Contributing](#contributing)

## Quick Start for Developers

Get running in 2 minutes:

```bash
git clone <repo-url>
cd superx/orchestrator
mix deps.get && mix compile
mix run --no-halt

# In another terminal
curl http://localhost:4000/health
```

No database. No external dependencies. That's it.

---

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
# Run all tests (excludes stress tests by default)
mix test

# Run all tests including stress tests
mix test --include stress

# Run specific test file
mix test test/agent/worker_test.exs

# Run with coverage report
mix coveralls
```

### Code Quality

```bash
# Format code
mix format

# Compile with warnings as errors
mix compile --warnings-as-errors

# Run all checks (format, compile, test)
mix format --check-formatted && mix compile --warnings-as-errors && mix test
```

## Development Workflow

### Typical Development Session

1. **Start interactive shell (hot reload)**
   ```bash
   iex -S mix
   ```
   Changes to `lib/` automatically reload in this session.

2. **In another terminal, watch tests**
   ```bash
   mix test --watch
   ```
   Tests re-run when you save files.

3. **Make changes** in `lib/orchestrator/` — see results immediately

4. **Before committing, run quality checks**
   ```bash
   mix format && mix compile --warnings-as-errors && mix test
   ```

### Quick Dev Commands

| Task | Command |
|------|---------|
| Start with hot reload | `iex -S mix` |
| Run tests once | `mix test` |
| Watch tests | `mix test --watch` |
| Format code | `mix format` |
| Full quality check | `mix format && mix compile --warnings-as-errors && mix test` |

## Project Structure

**Start here:** The key modules you'll work with:

```
lib/orchestrator/
├── router.ex                # ← HTTP/RPC endpoints (add new methods here)
├── agent/
│   ├── worker.ex           # ← Per-agent state & circuit breaker (key logic)
│   ├── registry.ex         # ← Agent discovery across cluster
│   ├── store.ex            # ← Agent config storage
│   ├── loader.ex           # ← YAML loading (modify for new config formats)
│   └── supervisor.ex       # ← Agent lifecycle management
├── task/
│   ├── store.ex            # ← Multi-turn conversation state
│   ├── pubsub.ex           # ← Event broadcasting
│   └── push_config.ex      # ← Webhook config
├── infra/
│   ├── http_client.ex      # ← HTTP calls to agents
│   ├── push_notifier.ex    # ← Webhook delivery logic
│   └── sse_client.ex       # ← Streaming responses
├── protocol/
│   ├── adapters/
│   │   ├── a2a.ex          # ← A2A protocol adapter
│   │   └── mcp.ex          # ← MCP protocol adapter
│   ├── envelope.ex         # ← Protocol-agnostic message format
│   ├── registry.ex         # ← Protocol version registry
│   └── methods.ex          # ← Method definitions & specs
└── mcp/                     # ← MCP protocol implementation
    ├── session.ex          # ← Stateful MCP session GenServer
    ├── client_handler.ex   # ← Bidirectional request handling
    ├── supervisor.ex       # ← MCP session supervision
    └── transport/
        ├── behaviour.ex    # ← Transport abstraction
        ├── http.ex         # ← HTTP + SSE transport
        └── stdio.ex        # ← STDIO transport for local servers

test/
├── agent/                  # ← Agent tests
├── task/                   # ← Task management tests
├── infra/                  # ← HTTP, webhooks, streaming tests
├── integration/            # ← End-to-end tests with real agents
└── stress/                 # ← Load/chaos testing
```

**What to edit for common tasks:**
- **New RPC method?** → `router.ex` + `protocol/methods.ex` + tests
- **New protocol?** → `protocol/adapters/` + `protocol/registry.ex`
- **Fix routing/circuit breaker?** → `agent/worker.ex`
- **Add task persistence?** → `task/store.ex`
- **Add MCP transport?** → `mcp/transport/` + `mcp/transport/behaviour.ex`
- **New feature?** → Create module in subdirectory + mirror in test/

## Common Development Tasks

### Adding a New RPC Method

1. Define spec in `lib/orchestrator/protocol/methods.ex`
2. Add handler in `lib/orchestrator/router.ex`
3. Write test in `test/protocol/methods_test.exs`
4. Test with curl:
   ```bash
   curl -X POST http://localhost:4000/rpc \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","id":1,"method":"my_method","params":{}}'
   ```

### Testing Agent Integration

Write integration test in `test/integration/`:
```bash
# Assumes agent running at http://localhost:8001
mix test --tag integration
```

### Debugging Agent State

```bash
iex(1)> Orchestrator.Agent.Registry.agents()
[{\"agent_name\", pid}]

iex(2)> {:ok, pid} = Orchestrator.Agent.Registry.lookup(\"agent_name\")
iex(3)> :sys.get_state(pid) |> IO.inspect(pretty: true)
```

### Checking Tasks

```bash
iex(1)> Orchestrator.Task.Store.all_tasks()
iex(2)> Orchestrator.Task.Store.get_task(\"task_id\")
```

---

## Debugging Guide

### Enable Debug Logging

**In interactive shell:**
```bash
iex(1)> Logger.configure(level: :debug)
```

**In code:**
```elixir
require Logger
Logger.debug(\"Debug message: #{inspect(data)}\")
```

**In config (dev.exs):**
```elixir
config :logger, level: :debug
```

### Common Issues

| Problem | Solution |
|---------|----------|
| Agent shows unhealthy | Check remote agent URL in config. View worker state: `:sys.get_state(pid)` |
| Circuit breaker open | Agent is failing. Check logs. Auto-recovers after threshold. |
| Task stuck in progress | Check `Task.Store.get_task(id)`. Manual cleanup: `Task.Store.delete_task(id)` |
| Memory growing | Check `Task.Store.all_tasks()` for stale ephemeral tasks |
| Tests hanging | Ensure agents running or use test fixtures. Check `AGENTS_FILE` |

---

### Storage Model

SuperX uses **OTP-distributed in-memory storage** via Horde and ETS:
- **No external database** — Start immediately, zero setup
- **Distributed** — Tasks replicated across cluster nodes
- **Ephemeral** — Suitable for stateless agent workflows
- **Future** — Database persistence coming in Phase 4+

### Supervision Tree

```
Orchestrator.Application
├── Orchestrator.Task.Store (GenServer + ETS + Horde)
├── Orchestrator.Task.PubSub (Elixir.PubSub)
├── Orchestrator.Task.PushConfig.Store (GenServer + ETS)
├── Orchestrator.Agent.Store (GenServer + ETS)
├── Orchestrator.Agent.Registry (Horde.Registry)
├── Orchestrator.Agent.Supervisor (Horde.DynamicSupervisor)
│   ├── Agent.Worker (per-agent GenServer with circuit breaker)
│   ├── Agent.Worker (per-agent GenServer with circuit breaker)
│   └── ...
├── Orchestrator.MCP.Supervisor (MCP session management)
│   ├── MCP.Session (per-MCP-agent stateful session)
│   ├── MCP.Session (per-MCP-agent stateful session)
│   └── ...
├── Orchestrator.Infra.PushNotifier (GenServer + async webhook delivery)
├── Orchestrator.Infra.HttpClient (Finch connection pool)
├── Orchestrator.Infra.Cluster (libcluster auto-discovery)
└── Bandit (HTTP server on :4000)
```

### Key Design Patterns

| Pattern | Implementation | Purpose |
|---------|---------------|---------|
| **Circuit Breaker** | `Agent.Worker` | Prevent cascade failures to unhealthy agents |
| **Backpressure** | `Agent.Worker` | Limit concurrent requests per agent |
| **Distributed Registry** | `Horde.Registry` | Track agents across cluster nodes |
| **Distributed Supervisor** | `Horde.DynamicSupervisor` | Supervise workers across cluster |
| **ETS Storage** | `Task.Store`, `Agent.Store` | Fast in-memory data access |
| **Protocol Adapters** | `Protocol.Adapters.*` | Pluggable protocol support (A2A, MCP) |
| **Transport Abstraction** | `MCP.Transport.Behaviour` | Pluggable MCP transports (HTTP, STDIO) |
| **Stateful Sessions** | `MCP.Session` | Persistent MCP connections with caching |

### Request Flow

**A2A Protocol:**
```
HTTP Request → Router → RPC.Router → Handler → Agent.Worker → Remote Agent
     ↓                                              ↓
  Response  ←──────────────────────────────────────┘
     ↓
Push.Notifier → Webhook (async)
```

**MCP Protocol:**
```
HTTP Request → Router → Handler → Agent.Worker → MCP.Session → Transport → MCP Server
     ↓                                              ↓
  Response  ←──────────────────────────────────────┘
     ↓                                              ↑
Push.Notifier → Webhook (async)               (HTTP/SSE/STDIO)
```

## Quick Reference

### Essential Commands

```bash
# Development
mix deps.get                  # Install dependencies
mix compile                   # Compile project
mix run --no-halt             # Start server (in-memory, no DB needed)
iex -S mix                    # Interactive shell with dependencies

# Testing  
mix test                      # Run all tests
mix test --include stress     # Include stress tests
mix coveralls                 # Coverage report

# Quality
mix format                    # Format code
mix compile --warnings-as-errors  # Check for warnings

# Production
mix escript.build             # Build standalone executable
mix release                   # Build release (see rel/)
```

### Key Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 4000 | HTTP server port |
| `AGENTS_FILE` | — | Path to agents YAML (for testing with local agents) |
| `SECRET_KEY_BASE` | — | Secret for crypto (required in prod) |
| `LOG_LEVEL` | info | Logging: debug, info, warning, error |
| `CLUSTER_STRATEGY` | — | Clustering: gossip, dns, kubernetes |

### API Quick Examples

```bash
# Health check
curl http://localhost:4000/health

# List agents
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"agents/list\",\"params\":{}}'

# Send message
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json\" \
  -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"message/send\",\"params\":{\"agent\":\"my_agent\",\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"Hello\"}]}}}'
```

## Contributing

1. **Setup**: Follow [Development Setup](#development-setup)
2. **Branch**: Create feature branch from `main` (e.g., `feature/smart-routing`)
3. **Code**: Follow [Code Style](#code-style) guidelines
4. **Test**: Run `mix test` — ensure all tests pass
5. **Format**: Run `mix format` before committing
6. **PR**: Submit with clear description of changes and motivation

### Code Style

- Follow standard Elixir conventions and idioms
- Use `mix format` before committing
- Add `@moduledoc` for modules and `@doc` for public functions
- Write descriptive test names: `test "routes message to agent based on skills"`
- Tag integration tests with `@tag :integration`
- Tag stress tests with `@tag :stress`
- Avoid deeply nested code — break into smaller functions
- Keep modules focused on single responsibility

## License

MIT License - see [LICENSE](../LICENSE) for details.

