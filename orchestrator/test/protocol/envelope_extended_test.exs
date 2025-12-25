defmodule Orchestrator.Protocol.EnvelopeExtendedTest do
  @moduledoc """
  Extended tests for Protocol.Envelope - internal message envelope.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Protocol.Envelope

  describe "new/1" do
    test "creates envelope with atom keys" do
      attrs = %{
        method: :send_message,
        task_id: "task-123",
        agent_id: "agent-1",
        message: %{"content" => "Hello"},
        rpc_id: "req-456"
      }

      env = Envelope.new(attrs)

      assert env.method == :send_message
      assert env.task_id == "task-123"
      assert env.agent_id == "agent-1"
      assert env.message == %{"content" => "Hello"}
      assert env.rpc_id == "req-456"
    end

    test "creates envelope with string keys" do
      attrs = %{
        "method" => "send_message",
        "taskId" => "task-123",
        "agentId" => "agent-1",
        "message" => %{"content" => "Hello"},
        "rpcId" => "req-456"
      }

      env = Envelope.new(attrs)

      assert env.method == "send_message"
      assert env.task_id == "task-123"
      assert env.agent_id == "agent-1"
      assert env.message == %{"content" => "Hello"}
      assert env.rpc_id == "req-456"
    end

    test "handles protocol and version" do
      attrs = %{
        method: :initialize,
        protocol: "mcp",
        version: "2024-11-05"
      }

      env = Envelope.new(attrs)

      assert env.protocol == "mcp"
      assert env.version == "2024-11-05"
    end

    test "handles context_id" do
      attrs = %{
        method: :send_message,
        context_id: "ctx-789"
      }

      env = Envelope.new(attrs)
      assert env.context_id == "ctx-789"
    end

    test "handles webhook" do
      attrs = %{
        method: :send_message,
        webhook: %{"url" => "https://example.com/hook"}
      }

      env = Envelope.new(attrs)
      assert env.webhook == %{"url" => "https://example.com/hook"}
    end

    test "handles payload" do
      attrs = %{
        method: :send_message,
        payload: %{"extra" => "data", "nested" => %{"key" => "value"}}
      }

      env = Envelope.new(attrs)
      assert env.payload == %{"extra" => "data", "nested" => %{"key" => "value"}}
    end

    test "handles metadata" do
      attrs = %{
        method: :send_message,
        metadata: %{"source" => "test", "trace_id" => "abc123"}
      }

      env = Envelope.new(attrs)
      assert env.metadata == %{"source" => "test", "trace_id" => "abc123"}
    end
  end

  describe "update/2" do
    test "updates envelope fields" do
      env = Envelope.new(%{method: :send_message, task_id: "task-1"})

      updated = Envelope.update(env, task_id: "task-2", agent_id: "new-agent")

      assert updated.task_id == "task-2"
      assert updated.agent_id == "new-agent"
      assert updated.method == :send_message
    end

    test "preserves unchanged fields" do
      env =
        Envelope.new(%{
          method: :send_message,
          task_id: "task-1",
          message: %{"content" => "Hello"}
        })

      updated = Envelope.update(env, task_id: "task-2")

      assert updated.task_id == "task-2"
      assert updated.message == %{"content" => "Hello"}
      assert updated.method == :send_message
    end
  end

  describe "streaming?/1" do
    test "returns true for stream_message method" do
      env = Envelope.new(%{method: :stream_message})
      assert Envelope.streaming?(env) == true
    end

    test "returns true for subscribe_task method" do
      env = Envelope.new(%{method: :subscribe_task})
      assert Envelope.streaming?(env) == true
    end

    test "returns false for send_message method" do
      env = Envelope.new(%{method: :send_message})
      assert Envelope.streaming?(env) == false
    end

    test "returns false for get_task method" do
      env = Envelope.new(%{method: :get_task})
      assert Envelope.streaming?(env) == false
    end

    test "returns false for MCP methods" do
      env = Envelope.new(%{method: :list_tools})
      assert Envelope.streaming?(env) == false
    end
  end
end
