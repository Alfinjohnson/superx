# Testing Guide

Comprehensive testing documentation for SuperX Orchestrator.

## Overview

SuperX has a comprehensive test suite with **210 tests** covering:
- Unit tests for individual modules
- Integration tests for API endpoints
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
# Exclude slow tests
mix test --exclude slow

# Run only integration tests
mix test --only integration

# Exclude postgres-only tests (memory mode)
mix test --exclude postgres_only

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
├── orchestrator/
│   ├── agent/
│   │   ├── loader_test.exs      # Agent loading tests
│   │   ├── registry_test.exs    # Registry tests
│   │   ├── worker_test.exs      # Worker & circuit breaker
│   │   └── supervisor_test.exs  # Supervision tree
│   │
│   ├── task/
│   │   ├── store_test.exs       # Task persistence
│   │   └── pubsub_test.exs      # Task subscriptions
│   │
│   ├── push/
│   │   ├── notifier_test.exs    # Webhook delivery
│   │   └── signer_test.exs      # HMAC/JWT signing
│   │
│   ├── protocol/
│   │   └── a2a_test.exs         # A2A protocol tests
│   │
│   └── web/
│       └── rpc_test.exs         # JSON-RPC endpoint tests
│
├── integration/
│   ├── message_flow_test.exs    # End-to-end message tests
│   ├── streaming_test.exs       # SSE streaming tests
│   └── agent_lifecycle_test.exs # Agent management tests
│
└── support/
    ├── fixtures/                # Test fixtures
    │   ├── agents.yml           # Sample agent config
    │   └── agent_card.json      # Sample agent card
    ├── mocks/                   # Mock modules
    │   └── mock_http.ex         # HTTP client mock
    ├── case.ex                  # Shared test case
    ├── conn_case.ex             # HTTP test helpers
    └── data_case.ex             # Database test helpers
```

### Test Tags

| Tag | Description | Usage |
|-----|-------------|-------|
| `@moduletag :postgres_only` | Requires PostgreSQL | Database-specific tests |
| `@tag :integration` | Integration test | End-to-end flows |
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
defmodule Orchestrator.Integration.MessageFlowTest do
  use Orchestrator.ConnCase

  @tag :integration

  describe "POST /rpc message/send" do
    test "sends message and returns task", %{conn: conn} do
      # Setup agent
      {:ok, _} = setup_test_agent("test_agent")

      # Send request
      response =
        conn
        |> post("/rpc", %{
          jsonrpc: "2.0",
          id: 1,
          method: "message/send",
          params: %{
            agent: "test_agent",
            message: %{role: "user", parts: [%{text: "Hello"}]}
          }
        })
        |> json_response(200)

      # Verify
      assert response["result"]["task"]["status"] in ["submitted", "completed"]
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
