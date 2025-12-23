defmodule Orchestrator.Protocol.EnvelopeTest do
  @moduledoc """
  Tests for the Protocol Envelope module.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Protocol.Envelope

  describe "new/1" do
    test "creates envelope with required method" do
      env = Envelope.new(%{method: :send_message})

      assert env.method == :send_message
      assert env.protocol == nil
      assert env.version == nil
      assert env.task_id == nil
    end

    test "creates envelope with all fields" do
      env = Envelope.new(%{
        protocol: "a2a",
        version: "0.3.0",
        method: :send_message,
        task_id: "task-123",
        context_id: "ctx-456",
        message: %{"role" => "user"},
        payload: %{"full" => "params"},
        metadata: %{"key" => "value"},
        agent_id: "agent-1",
        rpc_id: "rpc-1"
      })

      assert env.protocol == "a2a"
      assert env.version == "0.3.0"
      assert env.method == :send_message
      assert env.task_id == "task-123"
      assert env.context_id == "ctx-456"
      assert env.message == %{"role" => "user"}
      assert env.payload == %{"full" => "params"}
      assert env.metadata == %{"key" => "value"}
      assert env.agent_id == "agent-1"
      assert env.rpc_id == "rpc-1"
    end

    test "accepts string keys" do
      env = Envelope.new(%{
        "method" => :send_message,
        "taskId" => "task-from-string",
        "contextId" => "ctx-from-string"
      })

      assert env.method == :send_message
      assert env.task_id == "task-from-string"
      assert env.context_id == "ctx-from-string"
    end

    test "prefers atom keys over string keys" do
      env = Envelope.new(%{
        :method => :get_task,
        "method" => :send_message,
        :task_id => "atom-task",
        "taskId" => "string-task"
      })

      assert env.method == :get_task
      assert env.task_id == "atom-task"
    end

    test "keeps string method as-is (does not convert)" do
      env = Envelope.new(%{method: "send_message"})
      # String methods are not automatically converted to atoms
      assert env.method == "send_message"
    end

    test "keeps string method when not recognized" do
      env = Envelope.new(%{method: "custom_method"})
      assert env.method == "custom_method"
    end
  end

  describe "update/2" do
    test "updates single field" do
      original = Envelope.new(%{method: :send_message, task_id: "old"})
      updated = Envelope.update(original, task_id: "new")

      assert updated.task_id == "new"
      assert updated.method == :send_message
    end

    test "updates multiple fields" do
      original = Envelope.new(%{method: :send_message})
      updated = Envelope.update(original, [
        task_id: "task-1",
        context_id: "ctx-1",
        metadata: %{"updated" => true}
      ])

      assert updated.task_id == "task-1"
      assert updated.context_id == "ctx-1"
      assert updated.metadata == %{"updated" => true}
    end

    test "preserves unchanged fields" do
      original = Envelope.new(%{
        method: :send_message,
        protocol: "a2a",
        version: "0.3.0",
        agent_id: "agent-1"
      })
      updated = Envelope.update(original, task_id: "task-1")

      assert updated.protocol == "a2a"
      assert updated.version == "0.3.0"
      assert updated.agent_id == "agent-1"
    end
  end

  describe "streaming?/1" do
    test "returns true for streaming methods" do
      env = Envelope.new(%{method: :stream_message})
      assert Envelope.streaming?(env)
    end

    test "returns true for subscribe method" do
      env = Envelope.new(%{method: :subscribe_task})
      assert Envelope.streaming?(env)
    end

    test "returns false for non-streaming methods" do
      env = Envelope.new(%{method: :send_message})
      refute Envelope.streaming?(env)
    end

    test "returns false for get_task" do
      env = Envelope.new(%{method: :get_task})
      refute Envelope.streaming?(env)
    end
  end

  describe "struct enforcement" do
    test "method is required" do
      assert_raise ArgumentError, fn ->
        struct!(Envelope, [])
      end
    end
  end
end
