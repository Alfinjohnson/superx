# Orchestrator Project Structure

This document describes the restructured Elixir orchestrator codebase. The project has been reorganized for:
- **Easier developer collaboration** - Domain-driven folder organization
- **Future protocol support** - Protocol adapter pattern for extensibility
- **Better naming** - Consistent, descriptive module names
- **Reduced redundancy** - Shared utilities and extracted concerns

## Directory Structure

```
lib/orchestrator/
├── agent/                    # Agent management domain
│   ├── registry.ex           # Horde distributed registry
│   ├── store.ex              # Agent config storage (GenServer)
│   ├── supervisor.ex         # Horde DynamicSupervisor
│   └── worker.ex             # Per-agent GenServer (circuit breaker, dispatch)
│
├── infra/                    # Infrastructure/shared services
│   ├── cluster.ex            # Cluster status & load balancing
│   ├── http_client.ex        # Shared HTTP client
│   ├── push_notifier.ex      # Webhook dispatcher with retry
│   └── sse_client.ex         # Server-Sent Events client
│
├── protocol/                 # Protocol handling
│   ├── adapters/
│   │   └── a2a.ex            # A2A v0.3.0 protocol adapter
│   ├── a2a_template.ex       # A2A envelope templates
│   ├── behaviour.ex          # Protocol adapter behaviour
│   ├── envelope.ex           # Protocol-agnostic envelope
│   ├── methods.ex            # Method definitions
│   └── registry.ex           # Protocol adapter registry
│
├── schema/                   # Ecto schemas
│   ├── agent.ex              # Agent database schema
│   ├── push_config.ex        # Push notification config schema
│   └── task.ex               # Task database schema
│
├── task/                     # Task management domain
│   ├── pubsub.ex             # Task subscription/broadcast
│   ├── push_config.ex        # Push config management
│   └── store.ex              # Task persistence (GenServer)
│
├── web/                      # HTTP handling
│   └── rpc_errors.ex         # JSON-RPC error codes
│
├── application.ex            # OTP Application & supervision tree
├── repo.ex                   # Ecto Repo
├── router.ex                 # Plug router (HTTP endpoints)
└── utils.ex                  # Shared utilities
```

## Module Migration Guide

| Old Module | New Module | Notes |
|------------|------------|-------|
| `Orchestrator.AgentRegistry` | `Orchestrator.Agent.Store` | Config storage |
| `Orchestrator.AgentWorker` | `Orchestrator.Agent.Worker` | Per-agent worker |
| `Orchestrator.AgentSupervisor` | `Orchestrator.Agent.Supervisor` | Horde supervisor |
| `Orchestrator.TaskStore` | `Orchestrator.Task.Store` | Task persistence |
| `Orchestrator.PushNotifier` | `Orchestrator.Infra.PushNotifier` | Webhook delivery |
| `Orchestrator.StreamClient` | `Orchestrator.Infra.SSEClient` | SSE client |
| `Orchestrator.Cluster` | `Orchestrator.Infra.Cluster` | Cluster utilities |
| `Orchestrator.Envelope` | `Orchestrator.Protocol.Envelope` | Protocol envelope |
| `Orchestrator.Protocol.A2A` | `Orchestrator.Protocol.Adapters.A2A` | A2A adapter |
| `Orchestrator.AgentRecord` | `Orchestrator.Schema.Agent` | Agent schema |
| `Orchestrator.TaskRecord` | `Orchestrator.Schema.Task` | Task schema |
| `Orchestrator.PushConfigRecord` | `Orchestrator.Schema.PushConfig` | Push config schema |

**Note:** Backward compatibility aliases are provided for all old module names.

## Key Features

### Protocol Adapter Pattern

The protocol adapter pattern (`Orchestrator.Protocol.Behaviour`) allows easy addition of new protocols:

```elixir
defmodule Orchestrator.Protocol.Adapters.NewProtocol do
  @behaviour Orchestrator.Protocol.Behaviour
  
  # Implement callbacks...
end
```

### Shared Utilities

Common functions are consolidated in `Orchestrator.Utils`:

- `new_id/0` - Generate unique IDs
- `terminal_state?/1` - Check if task state is terminal
- `maybe_put/3` - Conditionally add to map
- `deep_merge/2` - Deep merge maps
- `now_iso8601/0` - Current ISO8601 timestamp

### Task Pub/Sub

Task updates are broadcast via `Orchestrator.Task.PubSub`:

```elixir
# Subscribe to task updates
TaskStore.subscribe(task_id)

# Receive updates
receive do
  {:task_update, task} -> handle_update(task)
end
```

### Push Notifications

Push configs are managed separately via `Orchestrator.Task.PushConfig`:

```elixir
# Set push config
PushConfig.set(task_id, %{"url" => "...", "token" => "..."})

# Deliver event to all configs
PushConfig.deliver_event(task_id, %{"statusUpdate" => ...})
```

## Configuration

The application is configured in `config/config.exs`:

```elixir
config :orchestrator,
  agents: %{...},           # Static agent config
  agents_file: "path/to",   # YAML agent file
  ecto_repos: [Orchestrator.Repo]
```

## Supervision Tree

```
Orchestrator.Supervisor
├── Cluster.Supervisor      # Optional clustering
├── Orchestrator.Repo       # Database
├── Finch                   # HTTP client pool
├── Task.Supervisor         # Async task runner
├── Horde.Registry          # Distributed registry
├── Agent.Supervisor        # Agent workers
├── Task.Store              # Task persistence
├── Task.PubSub             # Task subscriptions
├── Agent.Store             # Agent config
└── Plug.Cowboy             # HTTP server
```
