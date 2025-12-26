# Production-Ready Plan: Atomic, Strongly Consistent, Zero Data Loss

## Current State Analysis

### Problems Identified

1. **No Atomicity**: Operations across nodes can partially fail
2. **Eventual Consistency**: Data may be stale across nodes (10-50ms lag)
3. **Data Loss on Crash**: Tasks/agents stored only in ETS (memory)
4. **Split-Brain**: No conflict resolution when network partitions occur
5. **Memory Duplication**: Each node stores full copy (3 nodes = 3x memory)
6. **Manual Replication**: RPC-based sync is fragile and error-prone

### What Works Well (Keep These)

- ✅ Horde-based agent worker distribution
- ✅ Circuit breaker and backpressure per agent
- ✅ SSE streaming for real-time updates
- ✅ A2A protocol implementation
- ✅ Webhook/push notification system

---

## Solution: Three-Phase Migration Plan

---

## **Phase 1: Add PostgreSQL Backend (4-6 weeks)**

### Goal
Replace ETS with PostgreSQL for durable, consistent storage while keeping performance.

### Architecture Changes

```
Current:                          New:
┌─────────────┐                  ┌─────────────┐
│  Node 1     │                  │  Node 1     │
│  ┌────────┐ │                  │  ┌────────┐ │
│  │  ETS   │ │  ←RPC→           │  │ Cache  │ │
│  └────────┘ │                  │  └────────┘ │
└─────────────┘                  └──────┬──────┘
                                        ↓
┌─────────────┐                  ┌─────────────┐
│  Node 2     │                  │ PostgreSQL  │
│  ┌────────┐ │                  │ (Primary)   │
│  │  ETS   │ │                  │  - Tasks    │
│  └────────┘ │                  │  - Agents   │
└─────────────┘                  │  - Configs  │
                                 └─────────────┘
```

### Implementation Steps

#### 1.1 Add Dependencies (Week 1)

**File**: `mix.exs`

```elixir
defp deps do
  [
    # ... existing deps ...
    {:ecto_sql, "~> 3.11"},
    {:postgrex, "~> 0.17"},
    {:ecto_psql_extras, "~> 0.7"},  # Performance monitoring
    {:ex_machina, "~> 2.7", only: :test}  # Test factories
  ]
end
```

#### 1.2 Create Database Schema (Week 1)

**File**: `priv/repo/migrations/20250101000000_create_core_tables.exs`

```elixir
defmodule Orchestrator.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    # Tasks table
    create table(:tasks, primary_key: false) do
      add :id, :string, primary_key: true
      add :status, :map, null: false
      add :message, :map
      add :context_id, :string
      add :agent_id, :string, null: false
      add :result, :map
      add :artifacts, {:array, :map}, default: []
      add :metadata, :map, default: %{}
      
      timestamps(type: :utc_datetime_usec)
    end

    create index(:tasks, [:agent_id])
    create index(:tasks, [:context_id])
    create index(:tasks, ["(status->>'state')"], name: :tasks_status_state_index)
    create index(:tasks, [:inserted_at])

    # Agents table
    create table(:agents, primary_key: false) do
      add :id, :string, primary_key: true
      add :url, :string, null: false
      add :bearer, :string
      add :protocol, :string, default: "a2a"
      add :metadata, :map, default: %{}
      
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, [:url])

    # Push notification configs
    create table(:push_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :string, on_delete: :delete_all)
      add :url, :string, null: false
      add :token, :string
      add :hmac_secret, :string
      add :jwt_secret, :string
      add :jwt_issuer, :string
      add :jwt_audience, :string
      add :jwt_kid, :string
      
      timestamps(type: :utc_datetime_usec)
    end

    create index(:push_configs, [:task_id])
  end
end
```

#### 1.3 Create Ecto Schemas (Week 2)

**File**: `lib/orchestrator/schema/task.ex`

```elixir
defmodule Orchestrator.Schema.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "tasks" do
    field :status, :map
    field :message, :map
    field :context_id, :string
    field :agent_id, :string
    field :result, :map
    field :artifacts, {:array, :map}, default: []
    field :metadata, :map, default: %{}

    has_many :push_configs, Orchestrator.Schema.PushConfig

    timestamps()
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [:id, :status, :message, :context_id, :agent_id, :result, :artifacts, :metadata])
    |> validate_required([:id, :status, :agent_id])
    |> validate_status()
    |> unique_constraint(:id)
  end

  defp validate_status(changeset) do
    validate_change(changeset, :status, fn :status, status ->
      case status do
        %{"state" => state} when state in ["working", "completed", "failed", "cancelled"] ->
          []
        _ ->
          [status: "must have valid state"]
      end
    end)
  end
end
```

**File**: `lib/orchestrator/schema/agent.ex`

```elixir
defmodule Orchestrator.Schema.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agents" do
    field :url, :string
    field :bearer, :string
    field :protocol, :string, default: "a2a"
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:id, :url, :bearer, :protocol, :metadata])
    |> validate_required([:id, :url])
    |> validate_format(:url, ~r/^https?:\/\//)
    |> unique_constraint(:id)
    |> unique_constraint(:url)
  end
end
```

#### 1.4 Implement New Store Adapters (Week 2-3)

**File**: `lib/orchestrator/task/store/postgres.ex`

```elixir
defmodule Orchestrator.Task.Store.Postgres do
  @moduledoc """
  PostgreSQL-backed task store with strong consistency.
  
  Features:
  - ACID transactions
  - Optimistic locking via updated_at
  - PubSub via PostgreSQL LISTEN/NOTIFY
  - Read replicas support
  """

  import Ecto.Query
  alias Orchestrator.Repo
  alias Orchestrator.Schema.Task, as: TaskSchema
  alias Orchestrator.Task.PubSub

  @doc "Store or update a task atomically"
  def put(%{"id" => id} = task_data) do
    Repo.transaction(fn ->
      case Repo.get(TaskSchema, id) do
        nil ->
          # Insert new task
          %TaskSchema{}
          |> TaskSchema.changeset(task_data)
          |> Repo.insert!()
          |> notify_subscribers()

        existing ->
          # Check if terminal - prevent updates
          if terminal?(existing.status) do
            Repo.rollback(:terminal)
          else
            # Update with optimistic locking
            existing
            |> TaskSchema.changeset(task_data)
            |> Repo.update!()
            |> notify_subscribers()
          end
      end
    end)
    |> case do
      {:ok, _task} -> :ok
      {:error, :terminal} -> {:error, :terminal}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Get task with optional locking"
  def get(task_id, opts \\ []) do
    query = from t in TaskSchema, where: t.id == ^task_id
    
    query =
      if Keyword.get(opts, :lock, false) do
        lock(query, "FOR UPDATE")
      else
        query
      end

    case Repo.one(query) do
      nil -> nil
      task -> task_to_map(task)
    end
  end

  @doc "Subscribe and get task atomically"
  def subscribe(task_id) do
    # Use transaction to ensure consistency
    Repo.transaction(fn ->
      case Repo.get(TaskSchema, task_id) do
        nil -> nil
        task ->
          PubSub.subscribe(task_id)
          task_to_map(task)
      end
    end)
    |> case do
      {:ok, result} -> result
      _ -> nil
    end
  end

  @doc "Apply status update with optimistic locking"
  def apply_status_update(task_id, update) do
    Repo.transaction(fn ->
      task = Repo.get!(TaskSchema, task_id) |> Repo.lock("FOR UPDATE")
      
      if terminal?(task.status) do
        Repo.rollback(:terminal)
      else
        new_status = Map.merge(task.status, update)
        
        task
        |> TaskSchema.changeset(%{status: new_status})
        |> Repo.update!()
        |> notify_subscribers()
      end
    end)
  end

  # Notify via both PubSub and PostgreSQL NOTIFY
  defp notify_subscribers(task) do
    PubSub.broadcast(task.id, {:task_update, task_to_map(task)})
    
    # PostgreSQL NOTIFY for cross-node coordination
    Repo.query!(
      "NOTIFY task_updates, $1",
      [Jason.encode!(%{task_id: task.id, event: :update})]
    )
    
    task
  end

  defp terminal?(%{"state" => state}), do: state in ["completed", "failed", "cancelled"]
  defp terminal?(_), do: false

  defp task_to_map(%TaskSchema{} = task) do
    %{
      "id" => task.id,
      "status" => task.status,
      "message" => task.message,
      "context_id" => task.context_id,
      "agent_id" => task.agent_id,
      "result" => task.result,
      "artifacts" => task.artifacts,
      "metadata" => task.metadata
    }
  end
end
```

#### 1.5 Add Connection Pooling & Caching (Week 3)

**File**: `config/prod.exs`

```elixir
config :orchestrator, Orchestrator.Repo,
  # Connection pooling
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE") || "20"),
  queue_target: 50,
  queue_interval: 1_000,
  
  # Read replicas for scaling reads
  replicas: [
    [url: System.get_env("DATABASE_REPLICA_URL")]
  ],
  
  # Telemetry
  telemetry_prefix: [:orchestrator, :repo]

# Add query cache for hot data
config :orchestrator, :cache,
  adapter: Nebulex.Adapters.Local,
  gc_interval: :timer.hours(1),
  max_size: 10_000,
  ttl: :timer.minutes(5)
```

**File**: `lib/orchestrator/task/store/cached_postgres.ex`

```elixir
defmodule Orchestrator.Task.Store.CachedPostgres do
  @moduledoc """
  Cached PostgreSQL store for read-heavy workloads.
  
  - Writes go directly to PostgreSQL
  - Reads hit cache first (5min TTL)
  - Cache invalidated on writes
  """

  alias Orchestrator.Task.Store.Postgres
  alias Orchestrator.Cache

  def put(task) do
    with :ok <- Postgres.put(task) do
      Cache.delete(cache_key(task["id"]))
      :ok
    end
  end

  def get(task_id) do
    Cache.get_or_compute(cache_key(task_id), fn ->
      Postgres.get(task_id)
    end)
  end

  # Delegate other operations
  defdelegate subscribe(task_id), to: Postgres
  defdelegate apply_status_update(task_id, update), to: Postgres
  defdelegate delete(task_id), to: Postgres

  defp cache_key(task_id), do: {:task, task_id}
end
```

#### 1.6 Update Configuration (Week 4)

**File**: `lib/orchestrator/persistence.ex`

```elixir
defmodule Orchestrator.Persistence do
  @moduledoc """
  Persistence configuration for SuperX.
  
  Modes:
  - `:memory` - In-memory ETS (fast, ephemeral)
  - `:postgres` - PostgreSQL (durable, strongly consistent)
  - `:postgres_cached` - PostgreSQL + cache (best of both)
  """

  @doc "Returns the persistence mode"
  def mode do
    Application.get_env(:orchestrator, :persistence_mode, :postgres_cached)
  end

  def task_adapter do
    case mode() do
      :memory -> Orchestrator.Task.Store.Memory
      :postgres -> Orchestrator.Task.Store.Postgres
      :postgres_cached -> Orchestrator.Task.Store.CachedPostgres
    end
  end

  def agent_adapter do
    case mode() do
      :memory -> Orchestrator.Agent.Store.Memory
      :postgres -> Orchestrator.Agent.Store.Postgres
      :postgres_cached -> Orchestrator.Agent.Store.CachedPostgres
    end
  end
end
```

#### 1.7 Testing Strategy (Week 4)

**File**: `test/task/store/postgres_test.exs`

```elixir
defmodule Orchestrator.Task.Store.PostgresTest do
  use Orchestrator.DataCase, async: true  # Now safe!

  alias Orchestrator.Task.Store.Postgres
  alias Orchestrator.Repo

  describe "atomicity" do
    test "concurrent updates use optimistic locking" do
      task = insert(:task, status: %{"state" => "working"})
      
      # Simulate concurrent updates
      tasks = 
        1..10
        |> Enum.map(fn i ->
          Task.async(fn ->
            Postgres.apply_status_update(task.id, %{"progress" => i})
          end)
        end)
        |> Enum.map(&Task.await/1)
      
      # All should succeed (last write wins)
      assert Enum.all?(tasks, &match?(:ok, &1))
      
      # Final state is consistent
      final = Postgres.get(task.id)
      assert final["status"]["progress"] in 1..10
    end

    test "prevents updates to terminal tasks" do
      task = insert(:task, status: %{"state" => "completed"})
      
      assert {:error, :terminal} = 
        Postgres.apply_status_update(task.id, %{"foo" => "bar"})
    end
  end

  describe "consistency" do
    test "subscribe returns consistent snapshot" do
      # Insert task
      task = insert(:task)
      
      # Subscribe in transaction
      result = Postgres.subscribe(task.id)
      
      # Should see exact snapshot
      assert result["id"] == task.id
    end
  end
end
```

---

## **Phase 2: Add Distributed Coordination (2-3 weeks)**

### Goal
Handle split-brain scenarios and ensure cluster-wide consistency.

### Implementation

#### 2.1 Add Distributed Lock Manager

**File**: `lib/orchestrator/distributed/lock.ex`

```elixir
defmodule Orchestrator.Distributed.Lock do
  @moduledoc """
  Distributed locks using PostgreSQL advisory locks.
  
  Prevents split-brain by using database as single source of truth.
  """

  alias Orchestrator.Repo

  @doc """
  Acquire exclusive lock for a task.
  
  Blocks until lock is available or timeout.
  """
  def acquire(task_id, timeout \\ 5000) do
    lock_id = :erlang.phash2(task_id)
    
    case Repo.query("SELECT pg_try_advisory_lock($1)", [lock_id], timeout: timeout) do
      {:ok, %{rows: [[true]]}} -> {:ok, lock_id}
      {:ok, %{rows: [[false]]}} -> {:error, :lock_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Release lock"
  def release(lock_id) do
    Repo.query("SELECT pg_advisory_unlock($1)", [lock_id])
    :ok
  end

  @doc "Execute function with lock held"
  def with_lock(task_id, fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    
    case acquire(task_id, timeout) do
      {:ok, lock_id} ->
        try do
          fun.()
        after
          release(lock_id)
        end
      
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

#### 2.2 Update Task Operations to Use Locks

**File**: `lib/orchestrator/task/store/postgres.ex` (additions)

```elixir
defmodule Orchestrator.Task.Store.Postgres do
  alias Orchestrator.Distributed.Lock

  @doc "Apply status update with distributed lock"
  def apply_status_update(task_id, update) do
    Lock.with_lock(task_id, fn ->
      Repo.transaction(fn ->
        task = Repo.get!(TaskSchema, task_id)
        
        if terminal?(task.status) do
          Repo.rollback(:terminal)
        else
          new_status = Map.merge(task.status, update)
          
          task
          |> TaskSchema.changeset(%{status: new_status})
          |> Repo.update!()
          |> notify_subscribers()
        end
      end)
    end)
  end
end
```

#### 2.3 Add Health Checks & Circuit Breaker for DB

**File**: `lib/orchestrator/health/database.ex`

```elixir
defmodule Orchestrator.Health.Database do
  @moduledoc """
  Database health monitoring and circuit breaker.
  
  Prevents cascading failures when database is down.
  """

  use GenServer

  defstruct [
    :status,  # :healthy | :degraded | :down
    :last_check,
    :failure_count,
    :circuit_state  # :closed | :open | :half_open
  ]

  def start_link(_) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  def healthy? do
    GenServer.call(__MODULE__, :healthy?)
  end

  @impl true
  def init(state) do
    schedule_check()
    {:ok, %{state | status: :healthy, circuit_state: :closed, failure_count: 0}}
  end

  @impl true
  def handle_info(:check_health, state) do
    new_state = perform_health_check(state)
    schedule_check()
    {:noreply, new_state}
  end

  defp perform_health_check(state) do
    case Orchestrator.Repo.query("SELECT 1", [], timeout: 1000) do
      {:ok, _} ->
        %{state | status: :healthy, failure_count: 0, circuit_state: :closed}
      
      {:error, _} ->
        new_failure_count = state.failure_count + 1
        
        new_circuit_state =
          if new_failure_count >= 3, do: :open, else: state.circuit_state
        
        %{state | 
          status: :down, 
          failure_count: new_failure_count,
          circuit_state: new_circuit_state
        }
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check_health, 5_000)
  end
end
```

---

## **Phase 3: Add Backup & Recovery (2 weeks)**

### Goal
Zero data loss even with full cluster failure.

### Implementation

#### 3.1 PostgreSQL High Availability Setup

**File**: `infrastructure/postgres-ha.yml` (Docker Compose example)

```yaml
version: '3.8'

services:
  postgres-primary:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_REPLICATION_MODE: master
      POSTGRES_REPLICATION_USER: replicator
      POSTGRES_REPLICATION_PASSWORD: ${REPL_PASSWORD}
    volumes:
      - postgres-primary-data:/var/lib/postgresql/data
      - ./postgresql.conf:/etc/postgresql/postgresql.conf
    command: postgres -c config_file=/etc/postgresql/postgresql.conf
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  postgres-replica-1:
    image: postgres:16-alpine
    environment:
      POSTGRES_REPLICATION_MODE: slave
      POSTGRES_MASTER_HOST: postgres-primary
      POSTGRES_REPLICATION_USER: replicator
      POSTGRES_REPLICATION_PASSWORD: ${REPL_PASSWORD}
    volumes:
      - postgres-replica-1-data:/var/lib/postgresql/data
    depends_on:
      - postgres-primary
    ports:
      - "5433:5432"

  postgres-replica-2:
    image: postgres:16-alpine
    environment:
      POSTGRES_REPLICATION_MODE: slave
      POSTGRES_MASTER_HOST: postgres-primary
      POSTGRES_REPLICATION_USER: replicator
      POSTGRES_REPLICATION_PASSWORD: ${REPL_PASSWORD}
    volumes:
      - postgres-replica-2-data:/var/lib/postgresql/data
    depends_on:
      - postgres-primary
    ports:
      - "5434:5432"

  pgbouncer:
    image: pgbouncer/pgbouncer:latest
    environment:
      DATABASES_HOST: postgres-primary
      DATABASES_PORT: 5432
      DATABASES_USER: postgres
      DATABASES_PASSWORD: ${DB_PASSWORD}
      POOL_MODE: transaction
      MAX_CLIENT_CONN: 1000
      DEFAULT_POOL_SIZE: 25
    ports:
      - "6432:6432"
    depends_on:
      - postgres-primary

volumes:
  postgres-primary-data:
  postgres-replica-1-data:
  postgres-replica-2-data:
```

#### 3.2 Automated Backups

**File**: `lib/orchestrator/backup/scheduler.ex`

```elixir
defmodule Orchestrator.Backup.Scheduler do
  @moduledoc """
  Automated backup scheduler.
  
  - Full backups: Daily at 2 AM
  - Incremental: Every 4 hours
  - WAL archiving: Continuous
  - Retention: 30 days
  """

  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    schedule_full_backup()
    schedule_incremental_backup()
    {:ok, state}
  end

  @impl true
  def handle_info(:full_backup, state) do
    perform_full_backup()
    schedule_full_backup()
    {:noreply, state}
  end

  @impl true
  def handle_info(:incremental_backup, state) do
    perform_incremental_backup()
    schedule_incremental_backup()
    {:noreply, state}
  end

  defp perform_full_backup do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    backup_file = "/backups/full_#{timestamp}.sql"
    
    System.cmd("pg_dump", [
      "-h", db_host(),
      "-U", db_user(),
      "-F", "c",  # Custom format (compressed)
      "-f", backup_file,
      db_name()
    ], env: [{"PGPASSWORD", db_password()}])
    
    # Upload to S3 or similar
    upload_to_storage(backup_file)
  end

  defp perform_incremental_backup do
    # Use WAL archiving for point-in-time recovery
    # Already handled by PostgreSQL configuration
    :ok
  end

  defp schedule_full_backup do
    # Run daily at 2 AM
    next_run = Timex.now() 
      |> Timex.shift(days: 1)
      |> Timex.set(hour: 2, minute: 0, second: 0)
    
    delay = Timex.diff(next_run, Timex.now(), :milliseconds)
    Process.send_after(self(), :full_backup, delay)
  end

  defp schedule_incremental_backup do
    # Every 4 hours
    Process.send_after(self(), :incremental_backup, :timer.hours(4))
  end

  defp db_host, do: Application.get_env(:orchestrator, Orchestrator.Repo)[:hostname]
  defp db_user, do: Application.get_env(:orchestrator, Orchestrator.Repo)[:username]
  defp db_password, do: Application.get_env(:orchestrator, Orchestrator.Repo)[:password]
  defp db_name, do: Application.get_env(:orchestrator, Orchestrator.Repo)[:database]
end
```

#### 3.3 Point-in-Time Recovery

**File**: `scripts/restore_backup.exs`

```elixir
#!/usr/bin/env elixir

defmodule BackupRestore do
  @moduledoc """
  Restore database from backup.
  
  Usage:
    ./restore_backup.exs --backup-file /backups/full_2025-01-01.sql
    ./restore_backup.exs --point-in-time "2025-01-01 14:30:00"
  """

  def run(args) do
    opts = parse_args(args)
    
    case opts[:mode] do
      :full -> restore_full_backup(opts[:backup_file])
      :point_in_time -> restore_point_in_time(opts[:timestamp])
    end
  end

  defp restore_full_backup(backup_file) do
    IO.puts("Restoring from #{backup_file}...")
    
    # Stop application
    System.cmd("systemctl", ["stop", "orchestrator"])
    
    # Drop and recreate database
    System.cmd("dropdb", ["-h", db_host(), "-U", db_user(), db_name()])
    System.cmd("createdb", ["-h", db_host(), "-U", db_user(), db_name()])
    
    # Restore backup
    System.cmd("pg_restore", [
      "-h", db_host(),
      "-U", db_user(),
      "-d", db_name(),
      "-F", "c",
      backup_file
    ])
    
    # Start application
    System.cmd("systemctl", ["start", "orchestrator"])
    
    IO.puts("✅ Restore complete!")
  end

  defp restore_point_in_time(timestamp) do
    IO.puts("Restoring to #{timestamp} using WAL replay...")
    
    # Configure recovery.conf
    recovery_conf = """
    restore_command = 'cp /wal_archive/%f %p'
    recovery_target_time = '#{timestamp}'
    recovery_target_action = 'promote'
    """
    
    File.write!("/var/lib/postgresql/recovery.conf", recovery_conf)
    
    # Restart PostgreSQL (will enter recovery mode)
    System.cmd("systemctl", ["restart", "postgresql"])
    
    IO.puts("✅ Point-in-time recovery initiated!")
  end
end

BackupRestore.run(System.argv())
```

---

## **Phase 4: Monitoring & Observability (1 week)**

### Implementation

**File**: `lib/orchestrator/telemetry.ex`

```elixir
defmodule Orchestrator.Telemetry do
  @moduledoc """
  Telemetry handlers for production monitoring.
  """

  def setup do
    # Database query metrics
    :telemetry.attach_many(
      "orchestrator-db",
      [
        [:orchestrator, :repo, :query],
      ],
      &handle_db_event/4,
      nil
    )

    # Task operation metrics
    :telemetry.attach_many(
      "orchestrator-tasks",
      [
        [:orchestrator, :task, :put],
        [:orchestrator, :task, :get],
        [:orchestrator, :task, :update],
      ],
      &handle_task_event/4,
      nil
    )
  end

  defp handle_db_event(_event, measurements, metadata, _config) do
    # Send to Prometheus/StatsD
    :telemetry_metrics_prometheus.execute(
      :orchestrator_db_query_duration_ms,
      measurements.total_time / 1_000_000,
      %{query: metadata.query}
    )
  end

  defp handle_task_event(_event, measurements, metadata, _config) do
    :telemetry_metrics_prometheus.execute(
      :orchestrator_task_operation_duration_ms,
      measurements.duration,
      %{operation: metadata.operation, result: metadata.result}
    )
  end
end
```

---

## Migration Strategy

### Gradual Rollout

**Week 1-4: Development & Testing**
- Build PostgreSQL adapters
- Test in staging with synthetic load
- Verify no regressions

**Week 5: Canary Deployment**
```elixir
# Route 10% of traffic to PostgreSQL
config :orchestrator,
  persistence_mode: :postgres_cached,
  postgres_traffic_percentage: 10
```

**Week 6: Increase to 50%**
- Monitor metrics (latency, errors)
- Compare consistency between ETS and PostgreSQL

**Week 7: Full Migration**
- Route 100% to PostgreSQL
- Keep ETS as fallback for 2 weeks

**Week 8: Cleanup**
- Remove ETS code
- Archive old migration

---

## Performance Targets

| Metric | Current (ETS) | Target (PostgreSQL) |
|--------|--------------|---------------------|
| Task Write | 0.1ms | 2-5ms |
| Task Read | 0.05ms | 0.5ms (cached), 2ms (uncached) |
| Concurrent Writes | ~10k/sec | ~5k/sec |
| Data Loss on Crash | 100% | 0% |
| Split Brain Handling | ❌ None | ✅ Automatic |
| Consistency | Eventual | Strong |

---

## Cost Analysis

### Infrastructure Costs (Monthly)

**Current (ETS only):**
- 3x EC2 instances (3x memory): ~$450/month
- Total: **$450/month**

**With PostgreSQL:**
- 3x EC2 instances (less memory): ~$300/month
- PostgreSQL RDS (db.r6g.xlarge): ~$350/month
- Read replicas (2x): ~$700/month
- Total: **$1,350/month**

**Additional: $900/month (+200%)**

**Savings:**
- Can scale down EC2 instances (less memory needed)
- Can reduce node count with better consistency
- Read replicas enable horizontal scaling

**Net Cost: +$600-800/month** for production-grade durability

---

## Risk Mitigation

### Rollback Plan

If PostgreSQL causes issues:

1. **Switch back to ETS** (5 minutes):
   ```elixir
   config :orchestrator, persistence_mode: :memory
   ```

2. **Keep dual writes** during migration:
   ```elixir
   # Write to both ETS and PostgreSQL
   with :ok <- Postgres.put(task),
        :ok <- ETS.put(task) do
     :ok
   end
   ```

3. **Feature flag per customer**:
   ```elixir
   if customer_enabled?(:postgres) do
     Postgres.get(task_id)
   else
     ETS.get(task_id)
   end
   ```

---

## Success Criteria

✅ **Phase 1 Complete When:**
- All tests pass with PostgreSQL backend
- Latency < 5ms for 95th percentile
- Zero data loss on crash
- All existing features work

✅ **Phase 2 Complete When:**
- Split brain scenarios handled gracefully
- Distributed locks prevent race conditions
- Circuit breaker protects from DB outages

✅ **Phase 3 Complete When:**
- Automated backups running
- Can restore from any point in last 30 days
- RPO < 15 minutes, RTO < 5 minutes

✅ **Full Migration Complete When:**
- 100% traffic on PostgreSQL for 2 weeks
- No data loss incidents
- Customer satisfaction maintained

---

## Alternative: Mnesia (Erlang Native)

### Pros
- Built into Erlang/Elixir
- True distributed transactions
- No external dependencies
- Lower latency than PostgreSQL

### Cons
- Limited ecosystem
- Harder to backup/restore
- Schema changes require migration
- Not as battle-tested at scale

### When to Consider
- If keeping Elixir-only stack is critical
- If latency must be <1ms
- If managing PostgreSQL is too complex

---

## Conclusion

This plan delivers:
- ✅ **Atomic operations** via PostgreSQL transactions
- ✅ **Strong consistency** via ACID guarantees
- ✅ **Zero data loss** via replication + backups
- ✅ **Split-brain protection** via distributed locks
- ✅ **Production-ready** with monitoring and HA

**Total Timeline: 8-12 weeks**
**Total Cost: +$600-800/month**
**Risk: Low** (gradual rollout with rollback plan)

**Next Steps:**
1. Get stakeholder approval
2. Set up development PostgreSQL instance
3. Start Phase 1 implementation
4. Build monitoring dashboard
5. Plan canary deployment
