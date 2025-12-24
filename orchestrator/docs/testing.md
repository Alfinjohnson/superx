# Testing Guide

Comprehensive testing documentation for SuperX Orchestrator.

## Overview

SuperX has a comprehensive test suite with **210+ tests** covering:
- Unit tests for individual modules
- Integration tests for API endpoints and streaming
- Stress tests for high-load scenarios
- Behavior tests for persistence layers
- Circuit breaker and resilience testing

## Test Modes

SuperX supports two persistence modes for testing:

| Mode | Tests | Excluded | Database Required |
|------|-------|----------|-------------------|
| **Memory** | 173 | 37 postgres_only | No |
| **PostgreSQL** | 210 | 0 | Yes |

### Memory Mode (Fast)

Runs tests without a database. Ideal for rapid development.

```bash
# PowerShell
$env:SUPERX_PERSISTENCE="memory"; mix test --exclude postgres_only

# Linux/macOS
SUPERX_PERSISTENCE=memory mix test --exclude postgres_only

# cmd.exe
set SUPERX_PERSISTENCE=memory && mix test --exclude postgres_only
```

### PostgreSQL Mode (Full)

Runs the complete test suite including database-specific tests.

```bash
# Start database
docker compose -f ../docker-compose.yml up -d db

# Setup and run tests
# PowerShell
$env:SUPERX_PERSISTENCE="postgres"; mix ecto.setup; mix test

# Linux/macOS
SUPERX_PERSISTENCE=postgres mix ecto.setup && mix test
```

---

## Running Tests

### Basic Commands

```bash
# Run all tests (respects SUPERX_PERSISTENCE)
mix test

# Run with verbose output
mix test --trace

# Run a specific file
mix test test/orchestrator/agent/worker_test.exs

# Run a specific test (by line number)
mix test test/orchestrator/agent/worker_test.exs:42

# Run tests matching a pattern
mix test --only describe:"circuit breaker"
```

### Filtering Tests

```bash
# Exclude slow/stress tests
mix test --exclude slow --exclude stress

# Run only integration tests
mix test --only integration

# Exclude postgres-only tests (memory mode)
mix test --exclude postgres_only

# Run only stress tests
mix test --only stress

# Run only a specific tag
mix test --only circuit_breaker
```

### Parallel Execution

Tests run in parallel by default. To control parallelism:

```bash
# Run tests sequentially
mix test --max-cases 1

# Limit parallel cases
mix test --max-cases 4
```

---

## Test Coverage

### Running Coverage

```bash
# Generate coverage report
mix coveralls

# HTML report
mix coveralls.html

# Coverage with details
mix coveralls.detail
```

### Coverage Targets

| Category | Target | Current |
|----------|--------|---------|
| Overall | > 80% | ~85% |
| Core modules | > 90% | ~92% |
| Handlers | > 85% | ~88% |

### Viewing Reports

```bash
# Generate HTML report
mix coveralls.html

# Open in browser (Windows)
start cover/excoveralls.html

# Open in browser (macOS)
open cover/excoveralls.html
```

---

## Test Organization

### Directory Structure

```
test/
├── agent/
│   ├── loader_test.exs          # Agent loading tests
│   ├── registry_test.exs        # Registry tests
│   ├── worker_test.exs          # Worker & circuit breaker
│   └── supervisor_test.exs      # Supervision tree
│
├── task/
│   ├── store_test.exs           # Task persistence
│   └── pubsub_test.exs          # Task subscriptions
│
├── infra/
│   ├── http_client_test.exs     # HTTP client tests
│   ├── sse_client_test.exs      # SSE event parsing & dispatch
│   └── push_notifier_test.exs   # Webhook delivery & signing
│
├── protocol/
│   └── a2a_test.exs             # A2A protocol adapter tests
│
├── integration/
│   └── streaming_test.exs       # Router-level SSE streaming tests
│
├── stress/
│   └── stress_test.exs          # High-load & concurrent streaming tests
│
├── router_test.exs              # JSON-RPC endpoint integration tests
│
├── fixtures/
│   ├── agents.yml               # Sample agent config
│   └── agent_card.json          # Sample agent card
│
└── support/
    ├── case.ex                  # Shared test case
    ├── conn_case.ex             # HTTP test helpers
    ├── data_case.ex             # Database test helpers
    └── factory.ex               # Test data factories
```

### Test Tags

| Tag | Description | Usage |
|-----|-------------|-------|
| `@moduletag :postgres_only` | Requires PostgreSQL | Database-specific tests |
| `@tag :integration` | Integration test | End-to-end flows |
| `@tag :stress` | Stress/load test | High concurrency, long-running |
| `@tag :slow` | Slow test | Timeouts, retries |
| `@tag :circuit_breaker` | Circuit breaker tests | Resilience testing |

---

## Writing Tests

### Basic Test Structure

```elixir
defmodule Orchestrator.Agent.WorkerTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Agent.Worker

  describe "send_message/2" do
    test "sends message to healthy agent" do
      # Setup
      agent = build_agent("test_agent")
      {:ok, pid} = Worker.start_link(agent)

      # Exercise
      result = Worker.send_message(pid, build_message())

      # Verify
      assert {:ok, response} = result
      assert response.status == "completed"
    end

    test "returns error when circuit breaker is open" do
      agent = build_agent("failing_agent")
      {:ok, pid} = Worker.start_link(agent)

      # Trip circuit breaker
      for _ <- 1..5 do
        Worker.send_message(pid, build_failing_message())
      end

      # Verify rejection
      assert {:error, :circuit_open} = Worker.send_message(pid, build_message())
    end
  end

  # Helper functions
  defp build_agent(name) do
    %Orchestrator.Schema.Agent{
      name: name,
      url: "https://example.com/.well-known/agent.json"
    }
  end

  defp build_message do
    %{role: "user", parts: [%{text: "test"}]}
  end
end
```

### Testing with Mocks

```elixir
defmodule Orchestrator.Push.NotifierTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  describe "deliver/2" do
    test "sends webhook with HMAC signature" do
      # Setup mock
      Orchestrator.MockHttpClient
      |> expect(:post, fn url, body, headers ->
        assert url == "https://webhook.example.com"
        assert {"x-a2a-signature", _} = List.keyfind(headers, "x-a2a-signature", 0)
        {:ok, %{status: 200}}
      end)

      # Exercise
      push_config = %{url: "https://webhook.example.com", hmacSecret: "secret"}
      result = Notifier.deliver(push_config, %{task_id: "123"})

      # Verify
      assert :ok = result
    end
  end
end
```

### Database Tests

```elixir
defmodule Orchestrator.Task.DbStoreTest do
  use Orchestrator.DataCase  # Sets up sandbox

  @moduletag :postgres_only  # Skip in memory mode

  alias Orchestrator.Task.DbStore

  describe "create/1" do
    test "persists task to database" do
      task = %{id: Ecto.UUID.generate(), status: "submitted"}

      assert {:ok, saved} = DbStore.create(task)
      assert saved.id == task.id

      # Verify persistence
      assert {:ok, loaded} = DbStore.get(task.id)
      assert loaded.id == task.id
    end
  end
end
```

### Integration Tests

```elixir
defmodule Orchestrator.Integration.StreamingTest do
  use Orchestrator.ConnCase

  @moduletag :postgres_only

  describe "POST /rpc - message.stream" do
    test "streams events from agent successfully" do
      # Setup agent and stub
      agent = create_test_agent("streaming-agent")
      Req.Test.stub(Orchestrator.SSETest, fn conn ->
        stream_test_events(conn)
      end)

      # Make streaming request
      request = %{
        "jsonrpc" => "2.0",
        "id" => "stream-1",
        "method" => "message.stream",
        "params" => %{
          "agentId" => agent["id"],
          "message" => "test message"
        }
      }

      conn = json_post("/rpc", request)

      # Verify stream initialization response
      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["result"]["taskId"] != nil
    end
  end

  describe "POST /rpc - tasks.subscribe" do
    test "streams task updates via SSE" do
      # Create task
      task = create_test_task("task-1", "working")

      # Subscribe to task updates
      parent = self()

      Task.async(fn ->
        request = %{
          "jsonrpc" => "2.0",
          "id" => "sub-1",
          "method" => "tasks.subscribe",
          "params" => %{"taskId" => task["id"]}
        }

        conn = json_post("/rpc", request)
        assert conn.status == 200
        assert conn.state == :chunked
        send(parent, {:stream_started, conn})
      end)

      # Wait for subscription and update task
      assert_receive {:stream_started, _conn}, 1000
      update_task_status(task["id"], "completed")
    end
  end
end
```

### Stress Tests

```elixir
defmodule Orchestrator.StressTest do
  use Orchestrator.DataCase, async: false

  @moduletag :stress

  describe "Streaming stress" do
    @tag timeout: 120_000
    test "handles 50+ concurrent SSE connections" do
      # Create 50 tasks
      task_ids = create_test_tasks(50)
      parent = self()

      # Start 50 concurrent subscribers
      subscriber_tasks =
        Enum.map(task_ids, fn task_id ->
          Task.async(fn ->
            TaskStore.subscribe(task_id)
            send(parent, {:subscribed, task_id})

            receive do
              {:task_update, _task} -> 1
            after
              10_000 -> 0
            end
          end)
        end)

      # Wait for all subscriptions
      for _i <- 1..50, do: assert_receive {:subscribed, _}, 5_000

      # Broadcast updates to all tasks
      for task_id <- task_ids do
        TaskStore.apply_status_update(%{
          "taskId" => task_id,
          "statusUpdate" => %{"state" => "completed"}
        })
      end

      # Verify all received updates
      results = Task.await_many(subscriber_tasks, 15_000)
      assert Enum.sum(results) >= 45
    end

    @tag timeout: 90_000
    test "handles long-running streams (60s+)" do
      task_id = create_test_task("long-stream")
      
      # Subscribe for 60 seconds
      stream_task = Task.async(fn ->
        TaskStore.subscribe(task_id)
        collect_updates_for_duration(60_000, [])
      end)

      # Send updates every second for 60 seconds
      for i <- 1..60 do
        TaskStore.apply_status_update(%{
          "taskId" => task_id,
          "statusUpdate" => %{"message" => "Second #{i}"}
        })
        Process.sleep(1_000)
      end

      updates = Task.await(stream_task, 70_000)
      assert length(updates) >= 55
    end
  end
end
```

---

## Test Helpers

### DataCase (Database Tests)

```elixir
defmodule Orchestrator.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Orchestrator.Repo
      import Ecto
      import Ecto.Query
      import Orchestrator.DataCase
    end
  end

  setup tags do
    Orchestrator.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Orchestrator.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
```

### ConnCase (HTTP Tests)

```elixir
defmodule Orchestrator.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Orchestrator.ConnCase
      alias Orchestrator.Router
    end
  end

  setup _tags do
    {:ok, conn: Plug.Test.conn(:post, "/rpc")}
  end

  def json_response(conn, status) do
    assert conn.status == status
    Jason.decode!(conn.resp_body)
  end
end
```

---

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: superx_test
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4

      - name: Setup Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.19'
          otp-version: '28'

      - name: Install dependencies
        run: |
          cd orchestrator
          mix deps.get

      - name: Run memory mode tests
        run: |
          cd orchestrator
          SUPERX_PERSISTENCE=memory mix test --exclude postgres_only

      - name: Run PostgreSQL tests
        env:
          DATABASE_URL: ecto://postgres:postgres@localhost/superx_test
          SUPERX_PERSISTENCE: postgres
        run: |
          cd orchestrator
          mix ecto.setup
          mix test

      - name: Check formatting
        run: |
          cd orchestrator
          mix format --check-formatted
```

---

## Debugging Tests

### Verbose Output

```bash
# Show all test output
mix test --trace

# Show print statements
mix test --capture-log
```

### Running Single Tests

```bash
# Run specific test by line
mix test test/orchestrator/agent/worker_test.exs:42

# Run tests matching pattern
mix test --only describe:"circuit breaker"
```

### Interactive Debugging

```elixir
# Add to test
test "debugging example" do
  result = some_function()
  
  # Print to console
  IO.inspect(result, label: "result")
  
  # Break into IEx
  require IEx; IEx.pry()
  
  assert result == expected
end
```

Run with:

```bash
iex -S mix test test/path/to_test.exs:42
```

---

## Best Practices

1. **Async by default**: Use `async: true` unless tests share state
2. **Isolate database tests**: Use Ecto sandbox for clean state
3. **Mock external services**: Use Mox for HTTP clients
4. **Tag appropriately**: Use tags for filtering
5. **Keep tests fast**: Memory mode tests should complete in < 30s
6. **Test edge cases**: Circuit breakers, timeouts, errors
7. **Integration tests**: Cover critical paths end-to-end
