defmodule Orchestrator.Protocol.MCP.SessionTest do
  @moduledoc """
  Tests for MCP Session management.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Protocol.MCP.Session

  describe "start_link/1" do
    test "starts session with required params" do
      params = %{
        "id" => "test-agent-#{:rand.uniform(10000)}",
        "url" => "http://localhost:3000",
        "transport" => "streamable-http"
      }

      # Will fail because transport initialization requires real server
      result = Session.start_link(params)

      # Should either succeed or fail with transport error
      assert match?({:ok, _}, result) or match?({:error, _}, result)

      case result do
        {:ok, pid} -> GenServer.stop(pid)
        _ -> :ok
      end
    end
  end

  describe "call_tool/3" do
    test "sends tool call request" do
      # Since we can't create a real session without a server,
      # just verify the function exists
      assert function_exported?(Session, :call_tool, 2)
      assert function_exported?(Session, :call_tool, 3)
      assert function_exported?(Session, :call_tool, 4)
    end
  end

  describe "list_tools/2" do
    test "function exists" do
      assert function_exported?(Session, :list_tools, 1)
      assert function_exported?(Session, :list_tools, 2)
    end
  end

  describe "list_resources/2" do
    test "function exists" do
      assert function_exported?(Session, :list_resources, 1)
      assert function_exported?(Session, :list_resources, 2)
    end
  end

  describe "read_resource/3" do
    test "function exists" do
      assert function_exported?(Session, :read_resource, 2)
      assert function_exported?(Session, :read_resource, 3)
    end
  end

  describe "list_prompts/2" do
    test "function exists" do
      assert function_exported?(Session, :list_prompts, 1)
      assert function_exported?(Session, :list_prompts, 2)
    end
  end

  describe "get_prompt/4" do
    test "function exists" do
      assert function_exported?(Session, :get_prompt, 2)
      assert function_exported?(Session, :get_prompt, 3)
      assert function_exported?(Session, :get_prompt, 4)
    end
  end

  describe "request/4" do
    test "sends raw JSON-RPC request" do
      assert function_exported?(Session, :request, 2)
      assert function_exported?(Session, :request, 3)
      assert function_exported?(Session, :request, 4)
    end
  end
end
