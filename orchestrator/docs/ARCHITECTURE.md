# Architecture

Detailed system architecture and design documentation for SuperX Orchestrator.

## Overview

SuperX Orchestrator is built on Elixir/OTP, leveraging the BEAM VM's strengths for building fault-tolerant, concurrent systems. The architecture follows OTP conventions with a well-defined supervision tree and behavior-based abstractions for swappable implementations.

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              SuperX Gateway                                  │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         HTTP Layer (Bandit)                          │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                  │   │
│  │  │  /health    │  │    /rpc     │  │    SSE      │                  │   │
│  │  └─────────────┘  └──────┬──────┘  └─────────────┘                  │   │
│  └──────────────────────────┼───────────────────────────────────────────┘   │
│                             │                                               │
│  ┌──────────────────────────▼───────────────────────────────────────────┐   │
│  │                       RPC Router & Handlers                           │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐             │   │
│  │  │ message/ │  │  tasks/  │  │ agents/  │  │  admin/  │             │   │
│  │  │  send    │  │   get    │  │  list    │  │ methods  │             │   │
│  │  │ stream   │  │subscribe │  │ upsert   │  │          │             │   │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────────┘             │   │
│  └───────┼─────────────┼─────────────┼──────────────────────────────────┘   │
│          │             │             │                                       │
│  ┌───────▼─────────────▼─────────────▼──────────────────────────────────┐   │
│  │                        Core Services                                  │   │
│  │                                                                       │   │
│  │  ┌─────────────────┐  ┌───────────────────────────┐  ┌─────────────────────┐  │   │
│  │  │  Agent.Manager  │  │   Task.Store (Hybrid)     │  │   Push.Notifier     │  │   │
│  │  │  ┌───────────┐  │  │  ┌─────────────────────┐  │  │  ┌───────────────┐  │  │   │
│  │  │  │ Registry  │  │  │  │ Distributed (OTP)   │  │  │  │ HMAC Signer   │  │  │   │
│  │  │  ├───────────┤  │  │  │ Postgres (archive)  │  │  │  │ JWT Signer    │  │  │   │
│  │  │  │ Workers   │  │  │  └─────────────────────┘  │  │  │ Token Auth    │  │  │   │
│  │  │  └───────────┘  │  └───────────────────────────┘  │  └───────────────┘  │  │   │
│  │  └────────┬────────┘  └────────┬────────┘  └─────────┬───────────┘  │   │
│  └───────────┼────────────────────┼─────────────────────┼───────────────┘   │
│              │                    │                     │                    │
│  ┌───────────▼────────────────────▼─────────────────────▼───────────────┐   │
│  │                         Data Layer                                    │   │
│  │  ┌─────────────────┐  ┌───────────────────────────┐  ┌─────────────────────┐  │   │
│  │  │   Ecto.Repo     │  │   Distributed In-Memory   │  │   HttpClient        │  │   │
│  │  │  (PostgreSQL)   │  │   (OTP + ETS per node)    │  │    (Finch)          │  │   │
│  │  └─────────────────┘  └───────────────────────────┘  └─────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
                    ┌─────────────────────────────────────┐
                    │          Remote Agents              │
                    │  ┌─────┐  ┌─────┐  ┌─────┐         │
                    │  │ A1  │  │ A2  │  │ A3  │  ...    │
                    │  └─────┘  └─────┘  └─────┘         │
                    └─────────────────────────────────────┘
```

## Supervision Tree

```
Orchestrator.Application (Application)
│
├── Orchestrator.Repo (Ecto.Repo)
│   └── PostgreSQL Connection Pool
│
├── Orchestrator.Task.Store.Distributed (GenServer)
│   └── Hybrid in-memory task storage replicated across nodes (OTP/RPC)
│
├── Orchestrator.Task.PushConfig.Memory|Postgres (GenServer/Ecto)
│   └── Push config storage (memory or Postgres)
│
├── Orchestrator.Agent.Supervisor (Supervisor)
│   │
│   ├── Orchestrator.Agent.Registry (GenServer)
│   │   └── Agent metadata & routing table
│   │
│   └── Orchestrator.Agent.WorkerSupervisor (DynamicSupervisor)
│       ├── Agent.Worker (agent_1) ← GenServer per agent
│       ├── Agent.Worker (agent_2)
│       └── Agent.Worker (agent_n)
│
├── Orchestrator.Push.Notifier (GenServer)
│   └── Async webhook delivery with retries
│
├── Orchestrator.HttpClient (Finch)
│   └── HTTP connection pool
│
├── Orchestrator.Cluster.Topology (libcluster.Cluster)
│   └── Node discovery & clustering (enables distributed task replication)
│
└── Bandit (HTTP Server)
    └── Plug pipeline → Router
```

## Core Modules

For detailed module organization, see [Project Structure](project-structure.md).

### Agent Management

#### `Orchestrator.Agent.Registry`

Maintains the agent registry with routing information:

```elixir
# Key data structure
%Agent{
  name: "my_agent",
  url: "https://agent.example.com/.well-known/agent.json",
  bearer: "optional-token",
  card: %AgentCard{...},
  push: %PushConfig{...},
  config: %AgentConfig{...}
}
```

**Responsibilities:**
- Store and retrieve agent configurations
- Route requests to appropriate workers
- Persist agents (PostgreSQL) or keep in-memory (ETS)

#### `Orchestrator.Agent.Worker`

GenServer managing per-agent state:

```elixir
%State{
  agent: %Agent{...},
  breaker: :closed | :open | :half_open,
  in_flight: 0,
  max_in_flight: 10,
  failures: [],
  last_success: ~U[...],
  last_failure: nil
}
```

**Responsibilities:**
- Maintain circuit breaker state
- Enforce backpressure limits
- Execute A2A protocol requests
- Track request metrics

#### `Orchestrator.Agent.Loader`

Loads agents from configuration sources at startup:

```
Priority:
1. AGENTS_FILE (YAML file path)
2. Runtime API (agents/upsert)
3. Legacy A2A_REMOTE_URL/A2A_REMOTE_BEARER env vars
```

### Task Management

#### `Orchestrator.Task.Store`

Behavior-based task persistence:

```elixir
@callback create(task :: Task.t()) :: {:ok, Task.t()} | {:error, term()}
@callback get(id :: String.t()) :: {:ok, Task.t()} | {:error, :not_found}
@callback update(id :: String.t(), updates :: map()) :: {:ok, Task.t()} | {:error, term()}
@callback list(filters :: map()) :: {:ok, [Task.t()]}
```

**Implementations:**
- `Orchestrator.Task.MemoryStore` - ETS-backed for memory mode
- `Orchestrator.Task.DbStore` - PostgreSQL-backed for production

### Push Notifications

#### `Orchestrator.Push.Notifier`

Asynchronous webhook delivery:

```elixir
# Configuration per agent
%PushConfig{
  url: "https://app.example.com/webhooks/agent",
  token: nil,
  hmacSecret: "secret-key",
  jwtSecret: nil
}
```

**Features:**
- Async delivery (doesn't block request)
- Exponential backoff retry
- Configurable max attempts
- Multiple auth methods

### HTTP Client

#### `Orchestrator.HttpClient`

Finch-based HTTP client with connection pooling:

```elixir
# Pool configuration
config :orchestrator, Orchestrator.HttpClient,
  pool_size: 50,
  pool_timeout: 5_000
```

## Design Patterns

### Circuit Breaker

Protects against cascade failures when agents become unhealthy:

```
                    ┌──────────────────────────────────┐
                    │                                  │
     Success        │         CLOSED                   │     Failure count
    ◄───────────────│    (Normal operation)            │────────────────►
                    │                                  │   exceeds threshold
                    └──────────────────────────────────┘
                                    │
                                    │ Threshold exceeded
                                    ▼
                    ┌──────────────────────────────────┐
                    │                                  │
     Reject all     │          OPEN                    │
     requests       │    (Fast-fail mode)              │
    ◄───────────────│                                  │
                    └──────────────────────────────────┘
                                    │
                                    │ Cooldown expires
                                    ▼
                    ┌──────────────────────────────────┐
                    │                                  │
     Test request   │       HALF-OPEN                  │     Success
    ────────────────│    (Testing recovery)            │────────────────►
         │          │                                  │   (Return to CLOSED)
         │          └──────────────────────────────────┘
         │                          │
         │                          │ Failure
         └──────────────────────────┘ (Return to OPEN)
```

**Configuration:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `failureThreshold` | 5 | Failures to open circuit |
| `failureWindowMs` | 30000 | Window for counting failures |
| `cooldownMs` | 30000 | Wait before testing recovery |

### Backpressure

Limits concurrent requests per agent:

```elixir
def handle_call({:send_message, msg}, _from, state) do
  if state.in_flight >= state.max_in_flight do
    {:reply, {:error, :overloaded}, state}
  else
    # Process request
    {:reply, result, %{state | in_flight: state.in_flight + 1}}
  end
end
```

### Behavior Pattern

Allows swapping implementations based on configuration:

```elixir
# Compile-time module selection
@store_module Application.compile_env(:orchestrator, :task_store_module)

# Runtime dispatch
def get(id), do: @store_module.get(id)
```

## Persistence Modes

### PostgreSQL Mode (Default)

```
┌─────────────────────────────────────────────────────────────────┐
│                         PostgreSQL                               │
│                                                                 │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │     tasks       │  │     agents      │  │   agent_cards   │ │
│  │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │ │
│  │  │ id        │  │  │  │ name (PK) │  │  │  │ agent_name│  │ │
│  │  │ status    │  │  │  │ url       │  │  │  │ card_json │  │ │
│  │  │ history   │←─┼──┼──│ config    │  │  │  │ fetched_at│  │ │
│  │  │ artifacts │  │  │  │ push      │  │  │  └───────────┘  │ │
│  │  │ metadata  │  │  │  └───────────┘  │  └─────────────────┘ │
│  │  └───────────┘  │  └─────────────────┘                      │
│  └─────────────────┘                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Benefits:**
- Horizontal scaling (multiple nodes share state)
- Data durability
- Query capabilities
- JSONB for flexible schemas

### Memory Mode

```
┌─────────────────────────────────────────────────────────────────┐
│                          ETS Tables                              │
│                                                                 │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │  :tasks_table   │  │ :agents_table   │  │  :cards_table   │ │
│  │                 │  │                 │  │                 │ │
│  │ {id, task_map}  │  │ {name, agent}   │  │ {name, card}    │ │
│  │ {id, task_map}  │  │ {name, agent}   │  │ {name, card}    │ │
│  │ ...             │  │ ...             │  │ ...             │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Benefits:**
- Zero external dependencies
- Extremely fast (in-memory)
- Perfect for testing/development
- Edge deployments

**Trade-offs:**
- Data lost on restart
- No shared state between nodes
- Limited query capabilities

## Clustering

SuperX supports Erlang node clustering via libcluster for distributed deployments:

### Strategies

| Strategy | Use Case | Configuration |
|----------|----------|---------------|
| `gossip` | Local development | UDP multicast |
| `dns` | Docker/Kubernetes | DNS-based discovery |
| `kubernetes` | Kubernetes native | K8s API service discovery |

See [Configuration Guide](configuration.md) for cluster environment variables.

## Telemetry Events

SuperX emits telemetry events for observability:

### Agent Events

```elixir
# Request lifecycle
[:orchestrator, :agent, :call_start]
[:orchestrator, :agent, :call_stop]
[:orchestrator, :agent, :call_error]
[:orchestrator, :agent, :stream_start]

# Circuit breaker
[:orchestrator, :agent, :breaker_open]
[:orchestrator, :agent, :breaker_half_open]
[:orchestrator, :agent, :breaker_closed]
[:orchestrator, :agent, :breaker_reject]
[:orchestrator, :agent, :backpressure_reject]
```

### Push Events

```elixir
[:orchestrator, :push, :push_start]
[:orchestrator, :push, :push_success]
[:orchestrator, :push, :push_failure]
```

## Request Flow

### Synchronous Request (`message/send`)

```
1. HTTP POST /rpc
   ↓
2. Router.call/2 → parse JSON-RPC
   ↓
3. RPC.Router.dispatch/2 → route to handler
   ↓
4. MessageHandler.send/2
   ↓
5. Agent.Registry.get_worker/1 → find worker
   ↓
6. Agent.Worker.send_message/2
   ├── Check circuit breaker state
   ├── Check backpressure limit
   └── Execute request
       ↓
7. HttpClient.post/3 → call remote agent
   ↓
8. Process A2A response
   ↓
9. Task.Store.update/2 → persist task
   ↓
10. Push.Notifier.notify/2 → async webhook (if configured)
    ↓
11. Return JSON-RPC response
```

## Performance Considerations

### Connection Pooling

- **Database**: Ecto connection pool (default: 10 dev, 20 prod)
- **HTTP**: Finch pool (default: 50 connections)

### Tuning

```elixir
# Increase HTTP pool for high throughput
config :orchestrator, Orchestrator.HttpClient,
  pool_size: 100

# Increase DB pool for many concurrent requests
config :orchestrator, Orchestrator.Repo,
  pool_size: 50

# Increase per-agent concurrency
config :orchestrator, :agent_defaults,
  max_in_flight: 20
```
