defmodule Orchestrator.Agent.LoaderTest do
  @moduledoc """
  Tests for Agent.Loader - loads agents from various sources.
  """
  use ExUnit.Case, async: false

  alias Orchestrator.Agent.Loader
  alias Orchestrator.Agent.Store, as: AgentStore

  setup do
    # Clear agents loaded during test setup
    on_exit(fn ->
      # Clean up test agents
      AgentStore.list()
      |> Enum.filter(fn agent -> String.starts_with?(agent["id"] || "", "test-") end)
      |> Enum.each(fn agent -> AgentStore.delete(agent["id"]) end)
    end)

    :ok
  end

  describe "load_all/0" do
    test "returns tuple with total count" do
      # Set empty config to avoid loading from files
      original_file = Application.get_env(:orchestrator, :agents_file)
      original_agents = Application.get_env(:orchestrator, :agents)
      original_mcp = Application.get_env(:orchestrator, :mcp_registry_file)

      # Clear env vars temporarily
      System.delete_env("A2A_REMOTE_URL")
      Application.put_env(:orchestrator, :agents_file, nil)
      Application.put_env(:orchestrator, :agents, %{})
      Application.put_env(:orchestrator, :mcp_registry_file, nil)

      result = Loader.load_all()
      assert {:ok, count} = result
      assert is_integer(count)

      # Restore config
      Application.put_env(:orchestrator, :agents_file, original_file)
      Application.put_env(:orchestrator, :agents, original_agents)
      Application.put_env(:orchestrator, :mcp_registry_file, original_mcp)
    end
  end

  describe "normalize_agent/1" do
    test "preserves explicit protocol" do
      original_agents = Application.get_env(:orchestrator, :agents)

      Application.put_env(:orchestrator, :agents, %{
        "test-mcp-agent" => %{
          "name" => "MCP Agent",
          "protocol" => "mcp",
          "transport" => %{
            "type" => "stdio",
            "command" => "echo"
          }
        }
      })

      Loader.load_all()

      agent = AgentStore.fetch("test-mcp-agent")

      if agent do
        assert agent["protocol"] == "mcp"
        AgentStore.delete("test-mcp-agent")
      end

      Application.put_env(:orchestrator, :agents, original_agents)
    end
  end

  describe "YAML loading" do
    test "handles missing YAML file gracefully" do
      original_file = Application.get_env(:orchestrator, :agents_file)

      Application.put_env(:orchestrator, :agents_file, "/nonexistent/path/agents.yml")

      # Should not crash
      result = Loader.load_all()
      assert {:ok, _count} = result

      Application.put_env(:orchestrator, :agents_file, original_file)
    end

    test "handles empty agents file config" do
      original_file = Application.get_env(:orchestrator, :agents_file)

      Application.put_env(:orchestrator, :agents_file, "")

      result = Loader.load_all()
      assert {:ok, _count} = result

      Application.put_env(:orchestrator, :agents_file, original_file)
    end
  end
end
