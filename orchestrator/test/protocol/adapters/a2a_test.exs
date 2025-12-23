defmodule Orchestrator.Protocol.Adapters.A2ATest do
  @moduledoc """
  Tests for the A2A protocol adapter.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Protocol.Adapters.A2A
  alias Orchestrator.Protocol.Envelope

  describe "protocol_name/0 and protocol_version/0" do
    test "returns correct protocol name" do
      assert A2A.protocol_name() == "a2a"
    end

    test "returns correct protocol version" do
      assert A2A.protocol_version() == "0.3.0"
    end
  end

  describe "normalize_method/1" do
    test "normalizes PascalCase message methods" do
      assert A2A.normalize_method("SendMessage") == :send_message
      assert A2A.normalize_method("SendStreamingMessage") == :stream_message
    end

    test "normalizes slash-style message methods" do
      assert A2A.normalize_method("message/send") == :send_message
      assert A2A.normalize_method("message/stream") == :stream_message
    end

    test "normalizes PascalCase task methods" do
      assert A2A.normalize_method("GetTask") == :get_task
      assert A2A.normalize_method("ListTasks") == :list_tasks
      assert A2A.normalize_method("CancelTask") == :cancel_task
      assert A2A.normalize_method("SubscribeToTask") == :subscribe_task
    end

    test "normalizes slash-style task methods" do
      assert A2A.normalize_method("tasks/get") == :get_task
      assert A2A.normalize_method("tasks/list") == :list_tasks
      assert A2A.normalize_method("tasks/cancel") == :cancel_task
      assert A2A.normalize_method("tasks/subscribe") == :subscribe_task
    end

    test "normalizes push notification methods" do
      assert A2A.normalize_method("SetTaskPushNotificationConfig") == :set_push_config
      assert A2A.normalize_method("GetTaskPushNotificationConfig") == :get_push_config
      assert A2A.normalize_method("tasks/pushNotificationConfig/set") == :set_push_config
    end

    test "returns :unknown for unrecognized methods" do
      assert A2A.normalize_method("UnknownMethod") == :unknown
      assert A2A.normalize_method("invalid/method") == :unknown
    end
  end

  describe "wire_method/1" do
    test "converts canonical method to slash-style wire format" do
      assert A2A.wire_method(:send_message) == "message/send"
      assert A2A.wire_method(:stream_message) == "message/stream"
      assert A2A.wire_method(:get_task) == "tasks/get"
      assert A2A.wire_method(:list_tasks) == "tasks/list"
      assert A2A.wire_method(:cancel_task) == "tasks/cancel"
      assert A2A.wire_method(:subscribe_task) == "tasks/subscribe"
    end

    test "converts push notification methods to wire format" do
      assert A2A.wire_method(:set_push_config) == "tasks/pushNotificationConfig/set"
      assert A2A.wire_method(:get_push_config) == "tasks/pushNotificationConfig/get"
      assert A2A.wire_method(:list_push_configs) == "tasks/pushNotificationConfig/list"
      assert A2A.wire_method(:delete_push_config) == "tasks/pushNotificationConfig/delete"
    end

    test "falls back to string representation for unknown methods" do
      assert A2A.wire_method(:unknown_method) == "unknown_method"
    end
  end

  describe "encode/1" do
    test "encodes envelope to JSON-RPC format" do
      env =
        Envelope.new(%{
          method: :send_message,
          message: %{"role" => "user", "parts" => [%{"type" => "text", "text" => "Hello"}]},
          rpc_id: "test-123"
        })

      assert {:ok, payload} = A2A.encode(env)
      assert payload["jsonrpc"] == "2.0"
      assert payload["id"] == "test-123"
      assert payload["method"] == "message/send"
      assert payload["params"]["message"] == env.message
    end

    test "generates rpc_id if not provided" do
      env = Envelope.new(%{method: :send_message})

      assert {:ok, payload} = A2A.encode(env)
      assert is_binary(payload["id"])
      assert String.length(payload["id"]) > 0
    end

    test "includes task_id in params when provided" do
      env =
        Envelope.new(%{
          method: :get_task,
          task_id: "task-abc123",
          rpc_id: "rpc-1"
        })

      assert {:ok, payload} = A2A.encode(env)
      assert payload["params"]["id"] == "task-abc123"
      assert payload["params"]["taskId"] == "task-abc123"
    end

    test "includes context_id in params when provided" do
      env =
        Envelope.new(%{
          method: :send_message,
          context_id: "ctx-123",
          rpc_id: "rpc-1"
        })

      assert {:ok, payload} = A2A.encode(env)
      assert payload["params"]["contextId"] == "ctx-123"
    end

    test "includes metadata in params when provided" do
      env =
        Envelope.new(%{
          method: :send_message,
          metadata: %{"source" => "test"},
          rpc_id: "rpc-1"
        })

      assert {:ok, payload} = A2A.encode(env)
      assert payload["params"]["metadata"] == %{"source" => "test"}
    end
  end

  describe "decode/1" do
    test "decodes JSON-RPC request to envelope" do
      wire = %{
        "jsonrpc" => "2.0",
        "id" => "rpc-123",
        "method" => "message/send",
        "params" => %{
          "message" => %{"role" => "user", "parts" => [%{"text" => "Hi"}]},
          "contextId" => "ctx-456"
        }
      }

      assert {:ok, env} = A2A.decode(wire)
      assert env.protocol == "a2a"
      assert env.version == "0.3.0"
      assert env.method == :send_message
      assert env.rpc_id == "rpc-123"
      assert env.context_id == "ctx-456"
      assert env.message == %{"role" => "user", "parts" => [%{"text" => "Hi"}]}
    end

    test "decodes PascalCase method names" do
      wire = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "SendMessage",
        "params" => %{}
      }

      assert {:ok, env} = A2A.decode(wire)
      assert env.method == :send_message
    end

    test "extracts task_id from params" do
      wire = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks/get",
        "params" => %{"id" => "task-abc"}
      }

      assert {:ok, env} = A2A.decode(wire)
      assert env.task_id == "task-abc"
    end

    test "extracts task_id from taskId field" do
      wire = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks/get",
        "params" => %{"taskId" => "task-xyz"}
      }

      assert {:ok, env} = A2A.decode(wire)
      assert env.task_id == "task-xyz"
    end
  end

  describe "decode_stream_event/1" do
    test "decodes stream event with result" do
      data = Jason.encode!(%{"result" => %{"state" => "working"}})
      assert {:ok, %{"state" => "working"}} = A2A.decode_stream_event(data)
    end

    test "decodes stream event with error" do
      data = Jason.encode!(%{"error" => %{"code" => -32600, "message" => "Invalid"}})
      assert {:error, %{"code" => -32600, "message" => "Invalid"}} = A2A.decode_stream_event(data)
    end

    test "returns error for invalid JSON" do
      assert {:error, _} = A2A.decode_stream_event("not json")
    end
  end

  describe "well_known_path/0" do
    test "returns A2A agent card path" do
      assert A2A.well_known_path() == "/.well-known/agent-card.json"
    end
  end

  describe "resolve_card_url/1" do
    test "uses metadata agentCard URL if present" do
      agent = %{
        "url" => "http://agent.local/rpc",
        "metadata" => %{
          "agentCard" => %{
            "url" => "http://custom.local/card.json"
          }
        }
      }

      assert A2A.resolve_card_url(agent) == "http://custom.local/card.json"
    end

    test "constructs URL from agent URL + well-known path" do
      agent = %{"url" => "http://agent.local/rpc"}
      assert A2A.resolve_card_url(agent) == "http://agent.local/rpc/.well-known/agent-card.json"
    end

    test "handles agent URL without trailing path" do
      agent = %{"url" => "http://agent.local"}
      assert A2A.resolve_card_url(agent) == "http://agent.local/.well-known/agent-card.json"
    end
  end

  describe "normalize_agent_card/1" do
    test "normalizes minimal card" do
      card = %{
        "name" => "Test Agent",
        "url" => "http://test.local"
      }

      normalized = A2A.normalize_agent_card(card)

      assert normalized["name"] == "Test Agent"
      assert normalized["url"] == "http://test.local"
      assert normalized["version"] == "1.0.0"
      assert normalized["protocolVersion"] == "0.3.0"
      assert normalized["defaultInputModes"] == ["text/plain"]
      assert normalized["defaultOutputModes"] == ["text/plain"]
    end

    test "preserves existing version" do
      card = %{"name" => "Test", "url" => "http://test", "version" => "2.0.0"}
      normalized = A2A.normalize_agent_card(card)
      assert normalized["version"] == "2.0.0"
    end

    test "normalizes skills with default tags" do
      card = %{
        "name" => "Test",
        "url" => "http://test",
        "skills" => [
          %{"id" => "skill1", "name" => "Skill One"}
        ]
      }

      normalized = A2A.normalize_agent_card(card)

      assert [skill] = normalized["skills"]
      assert skill["id"] == "skill1"
      assert skill["tags"] == []
      assert skill["examples"] == []
    end

    test "preserves capabilities" do
      card = %{
        "name" => "Test",
        "url" => "http://test",
        "capabilities" => %{"streaming" => true, "pushNotifications" => true}
      }

      normalized = A2A.normalize_agent_card(card)
      assert normalized["capabilities"] == %{"streaming" => true, "pushNotifications" => true}
    end

    test "removes nil values" do
      card = %{"name" => "Test", "url" => "http://test"}
      normalized = A2A.normalize_agent_card(card)

      refute Map.has_key?(normalized, "description")
      refute Map.has_key?(normalized, "documentationUrl")
      refute Map.has_key?(normalized, "provider")
    end
  end

  describe "valid_card?/1" do
    test "returns true for card with name" do
      assert A2A.valid_card?(%{"name" => "Test Agent"})
      assert A2A.valid_card?(%{"name" => "Test", "url" => "http://test"})
    end

    test "returns false for card without name" do
      refute A2A.valid_card?(%{"url" => "http://test"})
      refute A2A.valid_card?(%{})
    end

    test "returns false for card with empty name" do
      refute A2A.valid_card?(%{"name" => ""})
    end

    test "returns false for non-map values" do
      refute A2A.valid_card?(nil)
      refute A2A.valid_card?("string")
      refute A2A.valid_card?([])
    end
  end

  describe "build_request/1" do
    test "builds complete JSON-RPC request from envelope" do
      env =
        Envelope.new(%{
          method: :send_message,
          message: %{"role" => "user", "parts" => [%{"text" => "Hello"}]},
          context_id: "ctx-1",
          rpc_id: "rpc-1"
        })

      request = A2A.build_request(env)

      assert request["jsonrpc"] == "2.0"
      assert request["id"] == "rpc-1"
      assert request["method"] == "message/send"
      assert request["params"]["message"] == env.message
      assert request["params"]["contextId"] == "ctx-1"
    end
  end

  describe "parse_response/1" do
    test "extracts result from successful response" do
      response = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "result" => %{"id" => "task-1", "status" => %{"state" => "completed"}}
      }

      assert {:ok, result} = A2A.parse_response(response)
      assert result["id"] == "task-1"
    end

    test "extracts error from error response" do
      response = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "error" => %{"code" => -32601, "message" => "Method not found"}
      }

      assert {:error, error} = A2A.parse_response(response)
      assert error["code"] == -32601
    end

    test "returns error for unexpected response format" do
      assert {:error, {:unexpected, %{}}} = A2A.parse_response(%{})
    end
  end

  describe "roundtrip encode/decode" do
    test "envelope survives encode -> decode cycle" do
      original =
        Envelope.new(%{
          method: :send_message,
          message: %{"role" => "user", "parts" => [%{"text" => "Test"}]},
          task_id: "task-123",
          context_id: "ctx-456",
          rpc_id: "rpc-789",
          metadata: %{"key" => "value"}
        })

      assert {:ok, wire} = A2A.encode(original)
      assert {:ok, decoded} = A2A.decode(wire)

      assert decoded.method == original.method
      assert decoded.message == original.message
      assert decoded.task_id == original.task_id
      assert decoded.context_id == original.context_id
      assert decoded.rpc_id == original.rpc_id
    end
  end
end
