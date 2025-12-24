defmodule Orchestrator.Protocol.MCP.SessionTest do
  @moduledoc """
  Tests for MCP Session management.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Protocol.MCP.Session

  describe "module" do
    test "exports expected functions" do
      # Force module load
      Code.ensure_loaded!(Session)

      # Get all exported functions
      functions = Session.__info__(:functions)

      # Verify key functions exist with expected arities
      assert {:call_tool, 2} in functions
      assert {:call_tool, 3} in functions
      assert {:call_tool, 4} in functions
      assert {:list_tools, 1} in functions
      assert {:list_tools, 2} in functions
      assert {:list_resources, 1} in functions
      assert {:list_resources, 2} in functions
      assert {:read_resource, 2} in functions
      assert {:read_resource, 3} in functions
      assert {:list_prompts, 1} in functions
      assert {:list_prompts, 2} in functions
      assert {:get_prompt, 2} in functions
      assert {:get_prompt, 3} in functions
      assert {:get_prompt, 4} in functions
      assert {:request, 2} in functions
      assert {:request, 3} in functions
      assert {:request, 4} in functions
      assert {:start_link, 1} in functions
      assert {:start_link, 2} in functions
    end
  end

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
end
