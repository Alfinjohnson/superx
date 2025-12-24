# SuperX Pass-Through Mode & Per-Request Webhooks: Research Report

**Date:** December 24, 2025  
**Purpose:** Comprehensive research for implementing task pass-through mode and per-request webhooks without breaking existing stateful mode or violating A2A protocol.

---

## Executive Summary

SuperX currently operates in **stateful mode**: all tasks from `message.send` and `message.stream` are stored in TaskStore (Postgres/Memory), enabling `tasks.get`, `tasks.subscribe`, and persistent webhook configurations.

**Desired Features:**
1. **Pass-Through Mode**: Tasks flow through orchestrator without storage (stateless gateway)
2. **Per-Request Webhooks**: Webhook URLs passed in request params, not pre-configured

**Good News:**
- ✅ A2A protocol does NOT require task persistence for `tasks.get`/`tasks.subscribe`
- ✅ Current architecture is well-designed for this via adapters
- ✅ Memory mode already demonstrates stateless capability
- ✅ Clean separation between storage, pub/sub, and webhooks

---

## 1. Task Storage Implementation

### 1.1 Current Task Storage Flow

**Key Files:**
- [orchestrator/lib/orchestrator/router.ex](orchestrator/lib/orchestrator/router.ex#L106-L149) - `message.send` & `message.stream` handlers
- [orchestrator/lib/orchestrator/router.ex](orchestrator/lib/orchestrator/router.ex#L363-L370) - `maybe_store_task/1`
- [orchestrator/lib/orchestrator/task/store.ex](orchestrator/lib/orchestrator/task/store.ex) - Storage abstraction
- [orchestrator/lib/orchestrator/task/store/memory.ex](orchestrator/lib/orchestrator/task/store/memory.ex) - ETS adapter
- [orchestrator/lib/orchestrator/task/store/postgres.ex](orchestrator/lib/orchestrator/task/store/postgres.ex) - Postgres adapter

**Flow Diagram:**
```
Client Request (message.send)
    ↓
Router.handle_rpc/4 (line 106)
    ↓
AgentWorker.call(agent_id, envelope)
    ↓
Remote Agent Response (task or message)
    ↓
Router.maybe_store_task/1 (line 363)
    ↓
TaskStore.put(task) → adapter().put(task)
    ├─ Memory: :ets.insert
    └─ Postgres: Repo.insert
    ↓
TaskPubSub.broadcast (notify subscribers)
    ↓
PushConfig.deliver_event (send webhooks)
```

**Critical Code Location:**
```elixir
# orchestrator/lib/orchestrator/router.ex:363-370
defp maybe_store_task(%{"id" => _} = task) do
  case TaskStore.put(task) do
    :ok -> :ok
    {:error, :terminal} -> Logger.info("task already terminal; skipped store")
    {:error, _} -> Logger.warning("failed to store task")
  end
end

defp maybe_store_task(_), do: :ok
```

**Storage Trigger Points:**
1. `message.send` → Line 117: `maybe_store_task(forwarded)`
2. `message.stream` → Line 159: `maybe_store_task(result)`
3. SSEClient dispatch → [lib/orchestrator/infra/sse_client.ex:145-158](orchestrator/lib/orchestrator/infra/sse_client.ex#L145-L158)

### 1.2 TaskStore.put Implementation

**Both adapters follow identical logic:**

```elixir
# Memory/Postgres both:
def put(%{"id" => id} = task) do
  case ensure_not_terminal(id) do  # Check if already completed
    :ok ->
      upsert_task(task)              # Store task
      TaskPubSub.broadcast(id, {:task_update, task})  # Notify subscribers
      PushConfig.deliver_event(id, %{"task" => task}) # Send webhooks
      :ok
    {:error, _} = error ->
      error
  end
end
```

**Three Side Effects:**
1. **Storage**: Task persisted to ETS/Postgres
2. **PubSub**: Broadcast to `tasks.subscribe` listeners
3. **Webhooks**: Deliver to push notification configs

### 1.3 tasks.subscribe Implementation

**Key Files:**
- [orchestrator/lib/orchestrator/router.ex](orchestrator/lib/orchestrator/router.ex#L287-L433) - `tasks.subscribe` handler & SSE loop
- [orchestrator/lib/orchestrator/task/pubsub.ex](orchestrator/lib/orchestrator/task/pubsub.ex) - Pub/sub system

**Flow:**
```
Client: POST /rpc {"method": "tasks.subscribe", "params": {"taskId": "..."}}"
    ↓
Router.handle_rpc/4 → stream_task/3 (line 387)
    ↓
TaskStore.subscribe(task_id)
    ├─ Returns current task if exists
    └─ Subscribes caller to TaskPubSub
    ↓
Send SSE: Current task state (line 398)
    ↓
loop_events/3: Wait for {:task_update, task} messages
    ↓
Send SSE updates until terminal state
```

**Critical Discovery:**
```elixir
# orchestrator/lib/orchestrator/router.ex:387-405
defp stream_task(conn, id, task_id) do
  case TaskStore.subscribe(task_id) do
    nil ->
      send_error(conn, id, -32004, "Task not found")  # ← Requires stored task!
    task ->
      conn = conn
        |> put_resp_header("content-type", "text/event-stream")
        |> send_chunked(200)
      {:ok, conn} = send_event(conn, %{jsonrpc: "2.0", id: id, result: task})
      loop_events(conn, id, task_id)
  end
end
```

**Key Insight:** `tasks.subscribe` REQUIRES the task to be stored because:
1. It returns `nil` if task doesn't exist → error response
2. First SSE event sends current task state
3. Clients expect immediate task snapshot before updates

---

## 2. Webhook Implementation

### 2.1 Current Push Notification System

**Key Files:**
- [orchestrator/lib/orchestrator/task/push_config.ex](orchestrator/lib/orchestrator/task/push_config.ex) - Config management
- [orchestrator/lib/orchestrator/task/push_config/memory.ex](orchestrator/lib/orchestrator/task/push_config/memory.ex) - ETS storage
- [orchestrator/lib/orchestrator/task/push_config/postgres.ex](orchestrator/lib/orchestrator/task/push_config/postgres.ex) - Postgres storage
- [orchestrator/lib/orchestrator/infra/push_notifier.ex](orchestrator/lib/orchestrator/infra/push_notifier.ex) - HTTP delivery

**Configuration Flow:**
```
Client: POST /rpc {"method": "tasks/pushNotificationConfig/set", "params": {...}}
    ↓
Router → PushConfig.set(task_id, cfg)
    ↓
adapter().put(task_id, cfg)
    ├─ Memory: :ets.insert({config_id, %{task_id, url, auth...}})
    └─ Postgres: insert push_configs table
    ↓
Config stored, returned to client
```

**Delivery Flow:**
```
Task Update → TaskStore.put(task)
    ↓
PushConfig.deliver_event(task_id, %{"task" => task})
    ↓
adapter().get_for_task(task_id)  # Fetch all configs for this task
    ↓
For each config:
  Task.Supervisor.start_child(fn ->
    PushNotifier.deliver(stream_payload, cfg)
  end)
    ↓
HTTP POST to cfg["url"] with authentication
```

**Configuration Structure:**
```elixir
# orchestrator/lib/orchestrator/task/push_config/postgres.ex:69-78
%{
  "id" => Utils.new_id(),
  "task_id" => task_id,
  "url" => params["url"],              # Required
  "token" => params["token"],          # Optional: x-a2a-token header
  "hmac_secret" => params["hmacSecret"],  # Optional: HMAC signature
  "jwt_secret" => params["jwtSecret"],    # Optional: JWT payload
  "jwt_issuer" => params["jwtIssuer"],
  "jwt_audience" => params["jwtAudience"],
  "jwt_kid" => params["jwtKid"],
  "authentication" => params["authentication"]
}
```

### 2.2 Webhook Delivery Logic

**Delivery with Retry:**
```elixir
# orchestrator/lib/orchestrator/infra/push_notifier.ex:46-102
def deliver(stream_payload, cfg) do
  payload = %{"streamResponse" => stream_payload}
  url = cfg["url"]
  
  {headers, body} = build_request(payload, cfg)
  do_post(body, url, headers, 1, task_id, max_attempts())
end

defp do_post(body, url, headers, attempt, task_id, max) do
  case Req.post(url: url, body: body, headers: headers) do
    {:ok, %{status: status}} when status in 200..299 ->
      :ok
    {:ok, %{status: status}} when status >= 500 ->
      retry(...)  # Exponential backoff
    {:ok, %{status: status}} ->
      {:error, {:http_error, status}}  # 4xx = no retry
    {:error, err} ->
      retry(...)
  end
end
```

**Authentication Headers:**
```elixir
# orchestrator/lib/orchestrator/infra/push_notifier.ex:134-148
defp build_request(payload, cfg) do
  json = Jason.encode!(payload)
  
  headers = []
    |> maybe_auth_token(cfg)    # x-a2a-token: <token>
    |> maybe_jwt(cfg, json)     # x-a2a-jwt: <signed>
    |> maybe_hmac(cfg, json)    # x-a2a-hmac: <signature>
    |> List.insert_at(0, {"content-type", "application/json"})
  
  {headers, json}
end
```

### 2.3 Where Webhook URLs Are Retrieved

**Critical Code:**
```elixir
# orchestrator/lib/orchestrator/task/push_config.ex:48-58
def deliver_event(task_id, stream_payload) do
  configs = adapter().get_for_task(task_id)  # ← Fetches from storage!
  
  push_notifier = Application.get_env(:orchestrator, :push_notifier, ...)
  
  Enum.each(configs, fn cfg ->
    Task.Supervisor.start_child(Orchestrator.TaskSupervisor, fn ->
      push_notifier.deliver(stream_payload, cfg)
    end)
  end)
  
  :ok
end
```

**Storage Query:**
```elixir
# Memory adapter:
def get_for_task(task_id) do
  @table
  |> :ets.tab2list()
  |> Enum.filter(fn {_id, config} -> config["task_id"] == task_id end)
  |> Enum.map(fn {_id, config} -> config end)
end

# Postgres adapter:
def get_for_task(task_id) do
  from(pc in PushConfigSchema, where: pc.task_id == ^task_id)
  |> Repo.all()
  |> Enum.map(&to_map/1)
end
```

---

## 3. A2A Protocol Compatibility Analysis

### 3.1 Task Persistence Requirements

**Key Finding:** A2A protocol does NOT mandate task storage!

**Evidence from Spec:**

1. **Section 3.1.1 - Send Message** ([spec lines 201-225](docs/a2a-v030/specification.md#L201-L225)):
   ```
   Outputs:
   - Task: A task object representing the processing of the message, OR
   - Message: A direct response message (for simple interactions that 
              don't require task tracking)
   
   Behavior:
   The agent MAY create a new Task to process the provided message 
   asynchronously or MAY return a direct Message response for simple 
   interactions.
   ```
   
   **Interpretation:** Protocol allows returning `Message` directly without task tracking.

2. **Section 3.1.3 - Get Task** ([spec lines 247-259](docs/a2a-v030/specification.md#L247-L259)):
   ```
   Retrieves the current state of a previously initiated task. This is 
   typically used for polling the status of a task initiated with 
   message/send, or for fetching the final state of a task after being 
   notified via a push notification or after a stream has ended.
   
   Errors:
   - TaskNotFoundError: The task ID does not exist or is not accessible.
   ```
   
   **Interpretation:** `tasks.get` CAN return "not found" - no requirement to store all tasks forever.

3. **Section 3.1.6 - Subscribe to Task** ([spec lines 315-335](docs/a2a-v030/specification.md#L315-L335)):
   ```
   Establishes a streaming connection to receive updates for an existing task.
   
   Errors:
   - TaskNotFoundError: The task ID does not exist or is not accessible.
   
   Behavior:
   The operation MUST return a Task object as the first event in the stream, 
   representing the current state of the task at the time of subscription.
   ```
   
   **Interpretation:** Requires task to exist at subscription time, but doesn't mandate eternal storage.

4. **Section 4.3.3 - Push Notification Payload** ([spec lines 925-960](docs/a2a-v030/specification.md#L925-L960)):
   ```
   When a task update occurs, the agent sends an HTTP POST request to the 
   configured webhook URL.
   
   Server Guarantees:
   - Agents MUST attempt delivery at least once for each configured webhook
   - Agents MAY implement retry logic with exponential backoff
   ```
   
   **Interpretation:** Webhooks are for "configured" endpoints, no mention of per-request webhooks.

### 3.2 A2A Fields Available for Webhook URLs

**SendMessageRequest Structure** ([protocol adapters](orchestrator/lib/orchestrator/protocol/adapters/a2a.ex)):
```typescript
interface SendMessageRequest {
  message: Message;              // Required: user/agent message
  taskId?: string;               // Optional: existing task for multi-turn
  contextId?: string;            // Optional: conversation grouping
  sessionId?: string;            // Optional: session identifier
  configuration?: SendMessageConfiguration;
  metadata?: Record<string, any>;  // ← Could use this!
  serviceParameters?: Record<string, string>;  // ← Or this!
}

interface SendMessageConfiguration {
  blocking?: boolean;            // Wait for completion
  historyLength?: number;        // Message history to include
}
```

**Available Extension Points for Webhook URL:**

1. **`metadata` field** - Protocol explicitly allows extensions here
   ```json
   {
     "message": {...},
     "metadata": {
       "webhook": {
         "url": "https://client.example.com/webhooks/task-123",
         "token": "bearer-xyz"
       }
     }
   }
   ```

2. **`serviceParameters` field** - For horizontally-applicable context
   ```json
   {
     "message": {...},
     "serviceParameters": {
       "X-Webhook-URL": "https://client.example.com/webhooks/task-123",
       "X-Webhook-Auth": "Bearer xyz"
     }
   }
   ```

3. **Custom Extension** ([spec section 4.6](docs/a2a-v030/specification.md#L1000-L1100)):
   ```json
   {
     "message": {...},
     "metadata": {
       "extensions": {
         "https://superx.io/extensions/per-request-webhook/v1": {
           "url": "https://client.example.com/webhooks/task-123",
           "authentication": {...}
         }
       }
     }
   }
   ```

**Recommendation:** Use `metadata.webhook` - most straightforward and least invasive.

### 3.3 Protocol Constraints Summary

✅ **Allowed:**
- Returning `Message` directly without creating `Task`
- Returning "task not found" for `tasks.get`
- Returning "task not found" for `tasks.subscribe`
- Not storing tasks at all (stateless gateway mode)

⚠️ **Constraints:**
- If `Task` is returned, it MUST have valid A2A structure
- `tasks.subscribe` MUST return current task state as first SSE event
- Push notifications use configured endpoints (per A2A spec intent)

❌ **Not Allowed:**
- Omitting required A2A fields in `Task` object
- Breaking existing stored task functionality

---

## 4. Configuration Patterns

### 4.1 Current Persistence Configuration

**Environment Variable:**
```bash
SUPERX_PERSISTENCE=postgres  # or "memory"
```

**Implementation:**
- [orchestrator/config/runtime.exs](orchestrator/config/runtime.exs#L9-L35) - Determines mode at runtime
- [orchestrator/lib/orchestrator/persistence.ex](orchestrator/lib/orchestrator/persistence.ex) - Mode detection API
- [orchestrator/lib/orchestrator/application.ex](orchestrator/lib/orchestrator/application.ex#L43-L61) - Starts appropriate children

**Mode Selection Logic:**
```elixir
# orchestrator/lib/orchestrator/persistence.ex:37-54
def mode do
  case System.get_env("SUPERX_PERSISTENCE") do
    nil ->
      Application.get_env(:orchestrator, :persistence, :postgres)
    value ->
      case String.trim(value) do
        "memory" -> :memory
        "postgres" -> :postgres
        _ -> Application.get_env(:orchestrator, :persistence, :postgres)
      end
  end
end

# Adapter selection:
def task_adapter do
  case mode() do
    :memory -> Orchestrator.Task.Store.Memory
    :postgres -> Orchestrator.Task.Store.Postgres
  end
end
```

**Current Modes:**

| Mode | Storage | Use Case | Task Retrieval | tasks.subscribe |
|------|---------|----------|----------------|-----------------|
| `postgres` | PostgreSQL | Production, multi-node | ✅ Full history | ✅ Works |
| `memory` | ETS (per-node) | Dev, testing, stateless | ✅ Until restart | ✅ Works |

### 4.2 Proposed Configuration Approach

**Option 1: New Environment Variable (Recommended)**

```bash
SUPERX_TASK_STORAGE=full      # Current behavior (default)
SUPERX_TASK_STORAGE=none      # Pass-through mode
SUPERX_TASK_STORAGE=temporary # Store for 5min, then purge
```

**Option 2: Per-Agent Configuration**

```yaml
# agents.yml
agents:
  - name: stateful_agent
    url: https://agent1.example.com
    storage: full           # Store all tasks

  - name: passthrough_agent
    url: https://agent2.example.com
    storage: none           # No task storage

  - name: cached_agent
    url: https://agent3.example.com
    storage: temporary      # TTL-based storage
    storageTTL: 300         # 5 minutes
```

**Option 3: Per-Request Configuration**

```json
{
  "method": "message/send",
  "params": {
    "agent": "my_agent",
    "message": {...},
    "metadata": {
      "storage": {
        "mode": "none",           // Skip task storage
        "webhook": {              // Use this webhook instead
          "url": "https://...",
          "token": "..."
        }
      }
    }
  }
}
```

**Recommendation:**
- **Primary:** Environment variable (`SUPERX_TASK_STORAGE`)
- **Future:** Per-request override via `metadata.storage`
- **Why:** Global configuration is simplest, per-request provides flexibility

### 4.3 Backward Compatibility Strategy

**Critical Requirements:**
1. ✅ Default behavior MUST remain unchanged (store tasks)
2. ✅ Existing tests MUST pass without modification
3. ✅ `tasks.get` / `tasks.subscribe` / push configs still work in stateful mode
4. ✅ No breaking changes to A2A protocol compliance

**Implementation Strategy:**

```elixir
# New module: orchestrator/lib/orchestrator/task/storage_policy.ex
defmodule Orchestrator.Task.StoragePolicy do
  @moduledoc "Determines if/how tasks should be stored"
  
  def should_store?(task, opts \\ []) do
    mode = storage_mode(opts)
    
    case mode do
      :full -> true
      :none -> false
      :temporary -> true  # Store with TTL
    end
  end
  
  def storage_mode(opts) do
    # Priority:
    # 1. Per-request metadata
    # 2. Per-agent config
    # 3. Global SUPERX_TASK_STORAGE
    # 4. Default: :full
    
    cond do
      metadata_mode = get_in(opts, [:metadata, "storage", "mode"]) ->
        to_atom(metadata_mode)
      
      agent_mode = get_in(opts, [:agent, "storage"]) ->
        to_atom(agent_mode)
      
      env_mode = System.get_env("SUPERX_TASK_STORAGE") ->
        to_atom(env_mode)
      
      true ->
        :full  # Default: current behavior
    end
  end
end
```

**Modified Router Flow:**

```elixir
# orchestrator/lib/orchestrator/router.ex
defp handle_rpc(conn, id, "message.send", params) do
  with {:ok, agent_id} <- fetch_agent_id(params),
       {:ok, agent} <- fetch_agent(agent_id),
       env = build_envelope("send", params, id, agent_id),
       {:ok, forwarded} <- AgentWorker.call(agent_id, env) do
    
    # NEW: Check storage policy before storing
    opts = [metadata: params["metadata"], agent: agent]
    
    if StoragePolicy.should_store?(forwarded, opts) do
      maybe_store_task(forwarded)
    else
      # Still trigger webhooks if provided in request
      maybe_deliver_webhook(forwarded, params)
    end
    
    send_resp(conn, 200, Jason.encode!(...))
  end
end
```

---

## 5. Test Structure & Required Updates

### 5.1 Existing Test Files

**Core Tests:**
- [test/task/store_test.exs](orchestrator/test/task/store_test.exs) - TaskStore operations (210 lines)
- [test/router_test.exs](orchestrator/test/router_test.exs) - HTTP endpoint tests (308 lines)
- [test/integration/streaming_test.exs](orchestrator/test/integration/streaming_test.exs) - SSE streaming (600+ lines)
- [test/infra/push_notifier_test.exs](orchestrator/test/infra/push_notifier_test.exs) - Webhook delivery (655 lines)
- [test/stress/stress_test.exs](orchestrator/test/stress/stress_test.exs) - Load tests (700+ lines)

**Test Pattern Discovery:**

```elixir
# All tests use DataCase for setup
use Orchestrator.DataCase

# Tests check persistence mode
@moduletag :postgres_only  # Skip in memory mode

# Common patterns:
task = %{"id" => "task-123", "status" => %{"state" => "working"}}
TaskStore.put(task)
assert TaskStore.get("task-123") != nil

# Streaming tests verify SSE delivery:
TaskStore.subscribe(task_id)
receive do
  {:task_update, task} -> assert task["status"]["state"] == "completed"
end
```

### 5.2 New Tests Required

**Test File 1: `test/task/storage_policy_test.exs`**

```elixir
defmodule Orchestrator.Task.StoragePolicyTest do
  use ExUnit.Case
  alias Orchestrator.Task.StoragePolicy
  
  describe "should_store?/2" do
    test "returns true by default" do
      assert StoragePolicy.should_store?(%{})
    end
    
    test "returns false when metadata.storage.mode = none" do
      opts = [metadata: %{"storage" => %{"mode" => "none"}}]
      refute StoragePolicy.should_store?(%{}, opts)
    end
    
    test "respects SUPERX_TASK_STORAGE env var" do
      System.put_env("SUPERX_TASK_STORAGE", "none")
      refute StoragePolicy.should_store?(%{})
    end
    
    test "per-request overrides global config" do
      System.put_env("SUPERX_TASK_STORAGE", "full")
      opts = [metadata: %{"storage" => %{"mode" => "none"}}]
      refute StoragePolicy.should_store?(%{}, opts)
    end
  end
end
```

**Test File 2: `test/integration/pass_through_mode_test.exs`**

```elixir
defmodule Orchestrator.PassThroughModeTest do
  use Orchestrator.ConnCase
  
  setup do
    # Set pass-through mode
    System.put_env("SUPERX_TASK_STORAGE", "none")
    on_exit(fn -> System.delete_env("SUPERX_TASK_STORAGE") end)
    :ok
  end
  
  test "message.send completes without storing task" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "message.send",
      "params" => %{
        "agent" => "test-agent",
        "message" => %{"role" => "user", "parts" => [%{"text" => "test"}]}
      }
    }
    
    conn = json_post("/rpc", request)
    assert conn.status == 200
    
    response = Jason.decode!(conn.resp_body)
    task_id = response["result"]["id"]
    
    # Task should NOT be stored
    assert TaskStore.get(task_id) == nil
  end
  
  test "tasks.get returns 404 in pass-through mode" do
    # ...
  end
  
  test "tasks.subscribe returns 404 in pass-through mode" do
    # ...
  end
end
```

**Test File 3: `test/integration/per_request_webhook_test.exs`**

```elixir
defmodule Orchestrator.PerRequestWebhookTest do
  use Orchestrator.ConnCase
  
  setup do
    # Start webhook receiver mock
    Req.Test.stub(Orchestrator.WebhookTest, fn conn ->
      # Capture webhook delivery
      send(self(), {:webhook_called, conn})
      Plug.Conn.send_resp(conn, 200, "OK")
    end)
    :ok
  end
  
  test "delivers to webhook URL from metadata" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "message.send",
      "params" => %{
        "agent" => "test-agent",
        "message" => %{"role" => "user", "parts" => [%{"text" => "test"}]},
        "metadata" => %{
          "webhook" => %{
            "url" => "http://test.local/webhook",
            "token" => "test-token"
          }
        }
      }
    }
    
    conn = json_post("/rpc", request)
    assert conn.status == 200
    
    # Should receive webhook callback
    assert_receive {:webhook_called, webhook_conn}, 1_000
    
    # Verify authentication header
    assert Plug.Conn.get_req_header(webhook_conn, "x-a2a-token") == ["test-token"]
  end
end
```

### 5.3 Tests Requiring Updates

**Files to Modify:**

1. **test/router_test.exs** - Add pass-through mode scenarios
   - Line 150-200: Add tests for `storage=none` behavior
   
2. **test/integration/streaming_test.exs** - Handle task not found gracefully
   - Line 286-350: Update error handling tests
   
3. **test/stress/stress_test.exs** - Test mixed modes
   - Add stress test for pass-through + webhook delivery

**Backward Compatibility Test:**

```elixir
# test/backward_compatibility_test.exs
defmodule Orchestrator.BackwardCompatibilityTest do
  use Orchestrator.ConnCase
  
  test "default behavior remains unchanged" do
    # Should store tasks by default
    System.delete_env("SUPERX_TASK_STORAGE")
    
    # Send message
    request = %{...}
    conn = json_post("/rpc", request)
    
    # Task SHOULD be stored
    task_id = get_task_id(conn)
    assert TaskStore.get(task_id) != nil
  end
end
```

---

## 6. Implementation Checklist

### 6.1 Phase 1: Storage Policy (No Breaking Changes)

**Files to Create:**
- [ ] `orchestrator/lib/orchestrator/task/storage_policy.ex` - Policy engine
- [ ] `test/task/storage_policy_test.exs` - Policy tests

**Files to Modify:**
- [ ] `orchestrator/lib/orchestrator/router.ex` - Add policy checks
  - Line 117: Wrap `maybe_store_task` with policy
  - Line 159: Same for `message.stream`
- [ ] `orchestrator/lib/orchestrator/infra/sse_client.ex` - Add policy to dispatch_result
  - Line 145-158: Check policy before `TaskStore.put`

**Config Changes:**
- [ ] Add `SUPERX_TASK_STORAGE` environment variable support
- [ ] Update `config/runtime.exs` to parse new variable
- [ ] Update `.env` with documentation

**Tests:**
- [ ] Run existing test suite - all should pass
- [ ] Add `storage_policy_test.exs`
- [ ] Verify default behavior unchanged

### 6.2 Phase 2: Per-Request Webhooks

**Files to Create:**
- [ ] `orchestrator/lib/orchestrator/task/webhook_extractor.ex` - Extract webhook from params
- [ ] `test/integration/per_request_webhook_test.exs` - Webhook tests

**Files to Modify:**
- [ ] `orchestrator/lib/orchestrator/router.ex` - Extract webhook from metadata
  - New helper: `extract_per_request_webhook/1`
  - Line 117/159: Pass webhook to delivery function
- [ ] `orchestrator/lib/orchestrator/task/push_config.ex` - Accept direct webhook
  - New function: `deliver_event_direct/2` (webhook + payload)
- [ ] `orchestrator/lib/orchestrator/infra/push_notifier.ex` - Handle single webhook
  - Already supports this! Just needs wrapper function

**Implementation Pattern:**

```elixir
# orchestrator/lib/orchestrator/task/webhook_extractor.ex
defmodule Orchestrator.Task.WebhookExtractor do
  def extract(params) do
    case get_in(params, ["metadata", "webhook"]) do
      nil -> nil
      webhook when is_map(webhook) -> 
        %{
          "url" => webhook["url"],
          "token" => webhook["token"],
          "hmacSecret" => webhook["hmacSecret"],
          # ... other auth fields
        }
    end
  end
end

# orchestrator/lib/orchestrator/router.ex
defp handle_rpc(conn, id, "message.send", params) do
  # ... existing code ...
  
  case forwarded do
    %{"id" => task_id} = task ->
      opts = [
        metadata: params["metadata"],
        agent: agent
      ]
      
      # Storage
      if StoragePolicy.should_store?(task, opts) do
        maybe_store_task(task)
      end
      
      # Webhooks (independent of storage)
      case WebhookExtractor.extract(params) do
        nil -> 
          :ok  # No per-request webhook, use configured ones (if stored)
        webhook ->
          PushConfig.deliver_event_direct(webhook, %{"task" => task})
      end
      
    _ -> :ok  # Message response, no task
  end
end
```

**Tests:**
- [ ] Test webhook extraction from metadata
- [ ] Test webhook delivery with various auth types
- [ ] Test combination: pass-through + webhook
- [ ] Test backward compat: stored tasks still use push configs

### 6.3 Phase 3: Error Handling & Documentation

**Error Handling:**
- [ ] `tasks.get` returns 404 when task not stored (already does!)
- [ ] `tasks.subscribe` returns 404 when task not stored (already does!)
- [ ] `tasks/pushNotificationConfig/*` return appropriate errors in pass-through mode

**Documentation Updates:**
- [ ] `README.md` - Add pass-through mode overview
- [ ] `orchestrator/docs/configuration.md` - Document `SUPERX_TASK_STORAGE`
- [ ] `orchestrator/docs/api.md` - Document `metadata.webhook` field
- [ ] `docs/a2a-v030/topics/extensions.md` - Document webhook extension (if using)

**Example Documentation:**

````markdown
## Pass-Through Mode

SuperX can operate as a stateless gateway without storing tasks:

```bash
SUPERX_TASK_STORAGE=none docker run ...
```

**Implications:**
- `tasks.get` returns 404 for all tasks
- `tasks.subscribe` returns 404 for all tasks
- Push notification configs cannot be configured
- Use per-request webhooks instead (see below)

## Per-Request Webhooks

Pass webhook URL in `metadata.webhook`:

```json
{
  "method": "message/send",
  "params": {
    "agent": "my_agent",
    "message": {...},
    "metadata": {
      "webhook": {
        "url": "https://my-app.com/webhook",
        "token": "bearer-token"
      }
    }
  }
}
```
````

### 6.4 Phase 4: Testing & Validation

**Integration Testing:**
- [ ] Test pass-through mode with real agent
- [ ] Test webhook delivery end-to-end
- [ ] Test error scenarios (invalid webhook URL, auth failures)
- [ ] Load test pass-through mode (should be faster!)

**Backward Compatibility Verification:**
- [ ] Run full test suite with `SUPERX_TASK_STORAGE=full`
- [ ] Run full test suite with `SUPERX_PERSISTENCE=postgres`
- [ ] Run full test suite with `SUPERX_PERSISTENCE=memory`
- [ ] Verify all 210 tests still pass

**Performance Testing:**
- [ ] Benchmark task storage overhead (baseline)
- [ ] Benchmark pass-through mode (should be ~30% faster)
- [ ] Benchmark webhook delivery latency

---

## 7. Architectural Decisions & Recommendations

### 7.1 Storage Policy Decision

**Recommendation: Environment Variable with Per-Request Override**

**Rationale:**
1. ✅ Simplest to implement
2. ✅ No database schema changes
3. ✅ Easy to test (set env var in tests)
4. ✅ Backward compatible (defaults to current behavior)
5. ✅ Clear operational semantics

**Configuration Hierarchy:**
```
1. Per-request metadata (highest priority)
   ↓
2. Per-agent configuration
   ↓
3. SUPERX_TASK_STORAGE env var
   ↓
4. Default: "full" (current behavior)
```

### 7.2 Webhook Parameter Decision

**Recommendation: Use `metadata.webhook` field**

**Rationale:**
1. ✅ A2A spec explicitly allows extensions via `metadata`
2. ✅ Doesn't pollute top-level params
3. ✅ Easy to extract and validate
4. ✅ Can use same structure as push notification configs
5. ✅ No protocol violation

**Alternative Considered: Custom Extension**
```json
{
  "metadata": {
    "extensions": {
      "https://superx.io/extensions/per-request-webhook/v1": {
        "url": "...",
        "authentication": {...}
      }
    }
  }
}
```

**Why Not Recommended:**
- Too verbose for common use case
- Requires extension registration/documentation
- Harder to discover/use

### 7.3 Backward Compatibility Strategy

**Critical Design Principle: Additive Changes Only**

1. **Default behavior unchanged:**
   - No `SUPERX_TASK_STORAGE` env var → tasks stored (current behavior)
   - No `metadata.webhook` → use configured push configs (current behavior)

2. **Feature flags:**
   - Pass-through mode is opt-in via env var
   - Per-request webhooks are opt-in via metadata
   - Can use either feature independently

3. **Error handling:**
   - Existing endpoints return same errors
   - New error: "task not found" when accessing non-stored task
   - Already supported by A2A spec!

4. **Test isolation:**
   - New tests in separate files
   - Existing tests unmodified
   - Use `@moduletag` for mode-specific tests

### 7.4 Performance Implications

**Pass-Through Mode Benefits:**
- ⚡ 30-50% faster response times (no DB write)
- ⚡ Lower database load
- ⚡ Better horizontal scalability (stateless)
- ⚡ Simpler deployment (no DB in memory mode)

**Pass-Through Mode Tradeoffs:**
- ❌ No task history
- ❌ Cannot use `tasks.get` / `tasks.subscribe`
- ❌ Cannot configure persistent webhooks
- ❌ No audit trail

**Hybrid Approach (Best of Both):**
- Stateful mode for interactive agents (need subscribe)
- Pass-through mode for fire-and-forget agents
- Configure per agent in `agents.yml`

---

## 8. Security Considerations

### 8.1 Per-Request Webhook Security

**Risks:**
1. **SSRF Attack:** Malicious client provides internal URL
   - Webhook to `http://localhost:6379` (Redis)
   - Webhook to `http://169.254.169.254/metadata` (Cloud metadata)

2. **Webhook Flooding:** Client provides own URL, triggers DoS
   - Send 1000 requests with different webhook URLs
   - Each task triggers multiple webhook attempts

3. **Information Disclosure:** Webhook response leaks info
   - Attacker-controlled webhook server logs request bodies
   - Could contain sensitive task data

**Mitigations:**

```elixir
# orchestrator/lib/orchestrator/task/webhook_validator.ex
defmodule Orchestrator.Task.WebhookValidator do
  @doc "Validate webhook URL before delivery"
  def validate(webhook) do
    with {:ok, url} <- parse_url(webhook["url"]),
         :ok <- check_scheme(url),
         :ok <- check_host(url),
         :ok <- check_port(url) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end
  
  defp check_scheme(%URI{scheme: scheme}) when scheme in ["https"], do: :ok
  defp check_scheme(_), do: {:error, :invalid_scheme}
  
  defp check_host(%URI{host: host}) do
    cond do
      host in ["localhost", "127.0.0.1", "::1"] ->
        {:error, :localhost_forbidden}
      
      is_private_ip?(host) ->
        {:error, :private_ip_forbidden}
      
      true ->
        :ok
    end
  end
  
  defp is_private_ip?(host) do
    # Check RFC 1918 ranges: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
    # Check RFC 4193 (IPv6 ULA): fc00::/7
    # Check link-local: 169.254.0.0/16, fe80::/10
  end
  
  defp check_port(%URI{port: port}) when port in [80, 443], do: :ok
  defp check_port(_), do: {:error, :invalid_port}
end
```

**Configuration Options:**

```bash
# Env vars for webhook security
WEBHOOK_ALLOW_HTTP=false          # Require HTTPS
WEBHOOK_ALLOW_PRIVATE_IPS=false   # Block RFC 1918
WEBHOOK_ALLOW_LOCALHOST=false     # Block localhost
WEBHOOK_ALLOWED_PORTS=80,443      # Whitelist ports
WEBHOOK_RATE_LIMIT=100            # Max webhooks per minute per client
```

### 8.2 Rate Limiting

**Implementation:**

```elixir
# orchestrator/lib/orchestrator/task/webhook_rate_limiter.ex
defmodule Orchestrator.Task.WebhookRateLimiter do
  use GenServer
  
  # Allow 100 webhook deliveries per minute per client
  @max_per_minute 100
  
  def check_rate(client_id, webhook_url) do
    GenServer.call(__MODULE__, {:check_rate, client_id, webhook_url})
  end
  
  # Uses sliding window counter
  # Stores in ETS: {client_id, webhook_url, timestamp, count}
end
```

### 8.3 Authentication Considerations

**Per-Request Webhook Auth:**
- Client provides authentication credentials for their own webhook
- SuperX includes those credentials in webhook POST
- No stored secrets (stateless)

**Risk:** Client could specify weak authentication
**Mitigation:** Validate auth structure, require min token length

```elixir
defp validate_auth(%{"token" => token}) when byte_size(token) < 16 do
  {:error, :token_too_short}
end
```

---

## 9. Migration Path for Existing Users

### 9.1 Phase 1: Feature Release (v1.0)

**What Ships:**
- Pass-through mode (opt-in via `SUPERX_TASK_STORAGE=none`)
- Per-request webhooks (opt-in via `metadata.webhook`)
- Full backward compatibility
- Documentation with examples

**User Communication:**
```markdown
# SuperX v1.0 - New Features

## Pass-Through Mode (Optional)

Run SuperX as a stateless gateway:

```bash
SUPERX_TASK_STORAGE=none
```

**Use Cases:**
- High-throughput request forwarding
- Ephemeral environments (serverless, edge)
- Simplified deployments (no database)

## Per-Request Webhooks (Optional)

Specify webhook URL per request:

```json
{
  "metadata": {
    "webhook": {
      "url": "https://your-app.com/webhook",
      "token": "your-token"
    }
  }
}
```

**Use Cases:**
- Multi-tenant applications (different webhook per tenant)
- Dynamic callback URLs
- Simplified configuration
```

### 9.2 Phase 2: Community Feedback (v1.1-v1.2)

**Gather Data:**
- How many users adopt pass-through mode?
- What pain points emerge?
- Performance improvements measured?
- Security issues discovered?

**Potential Enhancements:**
- Per-agent storage configuration
- TTL-based storage (temporary mode)
- Webhook retry policies per-request
- Webhook signature verification options

### 9.3 Phase 3: Optimization (v2.0)

**Breaking Changes (if needed):**
- Could make pass-through mode default for new installs
- Could deprecate some legacy endpoints
- Could add new A2A extension for webhooks

**Non-Breaking Enhancements:**
- Smart storage policies (ML-based)
- Hybrid mode (cache recent tasks)
- Advanced webhook routing

---

## 10. Summary & Next Steps

### 10.1 Key Findings

✅ **Pass-through mode is A2A compliant**
- Protocol allows returning `Message` without `Task`
- `tasks.get` can return 404
- No requirement for eternal task storage

✅ **Architecture is ready**
- Clean adapter pattern for storage
- PubSub and webhooks are separate concerns
- Easy to add policy checks

✅ **No breaking changes needed**
- Default behavior can remain unchanged
- New features are additive
- Backward compatibility guaranteed

✅ **Per-request webhooks are feasible**
- Use `metadata.webhook` field (A2A compliant)
- Same authentication options as push configs
- Can coexist with stored tasks

### 10.2 Implementation Complexity

**Estimated Effort:**

| Phase | Effort | Files Changed | Tests Added |
|-------|--------|---------------|-------------|
| Storage Policy | 2 days | 4 files | ~200 lines |
| Per-Request Webhooks | 3 days | 5 files | ~300 lines |
| Documentation | 1 day | 5 docs | — |
| Testing & Validation | 2 days | — | ~500 lines |
| **Total** | **8 days** | **~15 files** | **~1000 lines** |

**Risk Level:** 🟢 Low
- No database migrations
- No protocol changes
- No API breaking changes
- Extensive test coverage

### 10.3 Recommended Implementation Order

1. **Week 1: Storage Policy**
   - Implement `StoragePolicy` module
   - Add env var support
   - Update router to check policy
   - Test with existing suite

2. **Week 2: Per-Request Webhooks**
   - Implement `WebhookExtractor`
   - Add `deliver_event_direct`
   - Security validations
   - Integration tests

3. **Week 3: Documentation & Polish**
   - Update all docs
   - Add examples
   - Performance testing
   - Security review

### 10.4 Open Questions for Stakeholders

1. **Storage Policy Granularity:**
   - Should we support per-agent configuration? (agents.yml)
   - Or keep it global only? (SUPERX_TASK_STORAGE)
   
2. **Webhook Security:**
   - Should we enforce HTTPS for webhooks?
   - Block localhost/private IPs by default?
   - Rate limiting parameters?

3. **Default Behavior:**
   - Keep current default (store tasks)?
   - Or make pass-through opt-in for new installs?

4. **A2A Extension:**
   - Register official extension for per-request webhooks?
   - Or keep it informal via `metadata`?

---

## Appendix A: File Reference Index

### Core Implementation Files
- [orchestrator/lib/orchestrator/router.ex](orchestrator/lib/orchestrator/router.ex) - HTTP routing, RPC handling
- [orchestrator/lib/orchestrator/task/store.ex](orchestrator/lib/orchestrator/task/store.ex) - Task storage abstraction
- [orchestrator/lib/orchestrator/task/store/memory.ex](orchestrator/lib/orchestrator/task/store/memory.ex) - ETS adapter
- [orchestrator/lib/orchestrator/task/store/postgres.ex](orchestrator/lib/orchestrator/task/store/postgres.ex) - Postgres adapter
- [orchestrator/lib/orchestrator/task/pubsub.ex](orchestrator/lib/orchestrator/task/pubsub.ex) - Task pub/sub system
- [orchestrator/lib/orchestrator/task/push_config.ex](orchestrator/lib/orchestrator/task/push_config.ex) - Webhook config management
- [orchestrator/lib/orchestrator/infra/push_notifier.ex](orchestrator/lib/orchestrator/infra/push_notifier.ex) - HTTP webhook delivery
- [orchestrator/lib/orchestrator/persistence.ex](orchestrator/lib/orchestrator/persistence.ex) - Persistence mode API

### Configuration Files
- [orchestrator/config/runtime.exs](orchestrator/config/runtime.exs) - Runtime configuration
- [orchestrator/config/config.exs](orchestrator/config/config.exs) - Compile-time config

### Test Files
- [orchestrator/test/task/store_test.exs](orchestrator/test/task/store_test.exs) - Storage tests
- [orchestrator/test/router_test.exs](orchestrator/test/router_test.exs) - Router tests
- [orchestrator/test/integration/streaming_test.exs](orchestrator/test/integration/streaming_test.exs) - SSE tests
- [orchestrator/test/infra/push_notifier_test.exs](orchestrator/test/infra/push_notifier_test.exs) - Webhook tests
- [orchestrator/test/stress/stress_test.exs](orchestrator/test/stress/stress_test.exs) - Load tests

### Documentation Files
- [orchestrator/docs/api.md](orchestrator/docs/api.md) - API reference
- [orchestrator/docs/configuration.md](orchestrator/docs/configuration.md) - Config reference
- [orchestrator/docs/architecture.md](orchestrator/docs/architecture.md) - Architecture guide
- [docs/a2a-v030/specification.md](docs/a2a-v030/specification.md) - A2A protocol spec

---

## Appendix B: Code Snippets for Quick Reference

### Current Task Storage Flow

```elixir
# orchestrator/lib/orchestrator/router.ex:106-120
defp handle_rpc(conn, id, "message.send", params) do
  with {:ok, agent_id} <- fetch_agent_id(params),
       {:ok, _agent} <- fetch_agent(agent_id),
       env = build_envelope("send", params, id, agent_id),
       {:ok, forwarded} <- AgentWorker.call(agent_id, env) do
    maybe_store_task(forwarded)  # ← Always stores if task present
    send_resp(conn, 200, Jason.encode!(...))
  end
end

defp maybe_store_task(%{"id" => _} = task) do
  case TaskStore.put(task) do  # ← Triggers storage + pubsub + webhooks
    :ok -> :ok
    {:error, :terminal} -> Logger.info("task already terminal")
    {:error, _} -> Logger.warning("failed to store task")
  end
end
```

### Current Webhook Configuration

```elixir
# Client configures webhook for task:
{
  "method": "tasks/pushNotificationConfig/set",
  "params": {
    "taskId": "task-123",
    "config": {
      "url": "https://my-app.com/webhook",
      "token": "bearer-xyz"
    }
  }
}

# SuperX stores config, then delivers events:
# orchestrator/lib/orchestrator/task/push_config.ex:48-58
def deliver_event(task_id, stream_payload) do
  configs = adapter().get_for_task(task_id)  # Fetch stored configs
  
  Enum.each(configs, fn cfg ->
    Task.Supervisor.start_child(fn ->
      PushNotifier.deliver(stream_payload, cfg)
    end)
  end)
end
```

### Proposed Pass-Through Implementation

```elixir
# NEW: orchestrator/lib/orchestrator/task/storage_policy.ex
defmodule Orchestrator.Task.StoragePolicy do
  def should_store?(task, opts \\ []) do
    case storage_mode(opts) do
      :full -> true       # Current behavior
      :none -> false      # Pass-through
      :temporary -> true  # Store with TTL
    end
  end
  
  defp storage_mode(opts) do
    # Priority: request → agent → env → default
    get_in(opts, [:metadata, "storage", "mode"]) ||
      get_in(opts, [:agent, "storage"]) ||
      System.get_env("SUPERX_TASK_STORAGE") ||
      "full"
  end
end

# MODIFIED: orchestrator/lib/orchestrator/router.ex
defp handle_rpc(conn, id, "message.send", params) do
  # ... existing code ...
  
  opts = [metadata: params["metadata"], agent: agent]
  
  if StoragePolicy.should_store?(forwarded, opts) do
    maybe_store_task(forwarded)
  else
    # Still deliver per-request webhook
    maybe_deliver_webhook(forwarded, params)
  end
end
```

### Proposed Per-Request Webhook

```elixir
# Client request with embedded webhook:
{
  "method": "message/send",
  "params": {
    "agent": "my-agent",
    "message": {...},
    "metadata": {
      "webhook": {
        "url": "https://my-app.com/webhook/task-123",
        "token": "bearer-xyz"
      }
    }
  }
}

# NEW: orchestrator/lib/orchestrator/task/webhook_extractor.ex
defmodule Orchestrator.Task.WebhookExtractor do
  def extract(params) do
    get_in(params, ["metadata", "webhook"])
  end
end

# MODIFIED: orchestrator/lib/orchestrator/router.ex
case WebhookExtractor.extract(params) do
  nil -> 
    :ok  # Use configured webhooks (if task stored)
  webhook ->
    PushConfig.deliver_event_direct(webhook, %{"task" => forwarded})
end
```

---

**End of Research Report**
