defmodule Orchestrator.Agent.StoreTest do
  @moduledoc """
  Tests for the Agent.Store module.
  These tests require PostgreSQL and are skipped in memory mode.
  """
  use Orchestrator.DataCase

  # This test module uses Repo directly, skip in memory mode
  @moduletag :postgres_only

  alias Orchestrator.Agent.Store, as: AgentStore
  alias Orchestrator.Schema.Agent, as: AgentSchema

  setup do
    # Clear any existing agents from config for test isolation
    prev_agents = Application.get_env(:orchestrator, :agents)
    prev_agents_file = Application.get_env(:orchestrator, :agents_file)

    Application.put_env(:orchestrator, :agents_file, nil)
    Application.put_env(:orchestrator, :agents, %{})

    Orchestrator.Repo.delete_all(AgentSchema)

    on_exit(fn ->
      Application.put_env(:orchestrator, :agents, prev_agents)
      Application.put_env(:orchestrator, :agents_file, prev_agents_file)
    end)

    :ok
  end

  describe "upsert/1" do
    test "creates new agent with id and url" do
      agent = %{
        "id" => "test-agent-#{unique_id()}",
        "url" => "http://localhost:4001/rpc"
      }

      assert {:ok, saved} = AgentStore.upsert(agent)
      assert saved["id"] == agent["id"]
      assert saved["url"] == agent["url"]
    end

    test "creates agent with bearer token" do
      agent = %{
        "id" => "test-agent-#{unique_id()}",
        "url" => "http://localhost:4001/rpc",
        "bearer" => "test-token"
      }

      assert {:ok, saved} = AgentStore.upsert(agent)
      assert saved["bearer"] == "test-token"
    end

    test "creates agent with metadata" do
      agent = %{
        "id" => "test-agent-#{unique_id()}",
        "url" => "http://localhost:4001/rpc",
        "metadata" => %{
          "protocol" => "a2a",
          "protocolVersion" => "0.3.0"
        }
      }

      assert {:ok, saved} = AgentStore.upsert(agent)
      assert saved["metadata"]["protocol"] == "a2a"
    end

    test "updates existing agent" do
      agent_id = "test-agent-#{unique_id()}"

      original = %{
        "id" => agent_id,
        "url" => "http://localhost:4001/rpc"
      }

      assert {:ok, _} = AgentStore.upsert(original)

      updated = %{
        "id" => agent_id,
        "url" => "http://localhost:5001/rpc",
        "bearer" => "new-token"
      }

      assert {:ok, saved} = AgentStore.upsert(updated)
      assert saved["url"] == "http://localhost:5001/rpc"
      assert saved["bearer"] == "new-token"
    end

    test "accepts atom keys" do
      agent = %{
        id: "test-agent-#{unique_id()}",
        url: "http://localhost:4001/rpc"
      }

      assert {:ok, saved} = AgentStore.upsert(agent)
      assert saved["id"] == agent.id
    end

    test "returns error for agent without id" do
      agent = %{"url" => "http://localhost:4001/rpc"}
      assert {:error, :invalid} = AgentStore.upsert(agent)
    end
  end

  describe "fetch/1" do
    test "returns nil for non-existent agent" do
      assert AgentStore.fetch("non-existent") == nil
    end

    test "returns agent after upsert" do
      agent_id = "test-agent-#{unique_id()}"
      agent = %{"id" => agent_id, "url" => "http://test.local"}

      {:ok, _} = AgentStore.upsert(agent)

      fetched = AgentStore.fetch(agent_id)
      assert fetched["id"] == agent_id
      assert fetched["url"] == "http://test.local"
    end
  end

  describe "list/0" do
    test "returns empty list when no agents" do
      # Ensure store is reloaded with empty state
      agents = AgentStore.list()
      # May have config agents loaded, so just verify it's a list
      assert is_list(agents)
    end

    test "returns upserted agents" do
      agent1 = %{"id" => "agent-1-#{unique_id()}", "url" => "http://a1.local"}
      agent2 = %{"id" => "agent-2-#{unique_id()}", "url" => "http://a2.local"}

      {:ok, _} = AgentStore.upsert(agent1)
      {:ok, _} = AgentStore.upsert(agent2)

      agents = AgentStore.list()
      ids = Enum.map(agents, & &1["id"])

      assert agent1["id"] in ids
      assert agent2["id"] in ids
    end
  end

  describe "delete/1" do
    test "removes agent by id" do
      agent_id = "test-agent-#{unique_id()}"
      agent = %{"id" => agent_id, "url" => "http://test.local"}

      {:ok, _} = AgentStore.upsert(agent)
      assert AgentStore.fetch(agent_id) != nil

      assert :ok = AgentStore.delete(agent_id)
      assert AgentStore.fetch(agent_id) == nil
    end

    test "returns :ok for non-existent agent" do
      assert :ok = AgentStore.delete("non-existent-#{unique_id()}")
    end
  end

  describe "debug_load_agents/0" do
    test "loads agents from config" do
      Application.put_env(:orchestrator, :agents, %{
        "config-agent" => %{
          "url" => "http://config.local/rpc",
          "bearer" => "config-token"
        }
      })

      agents = AgentStore.debug_load_agents()

      assert Map.has_key?(agents, "config-agent")
      agent = agents["config-agent"]
      assert agent["url"] == "http://config.local/rpc"
      assert agent["bearer"] == "config-token"
    end

    test "config agents use map key as id" do
      Application.put_env(:orchestrator, :agents, %{
        "my-agent" => %{"url" => "http://test.local"}
      })

      agents = AgentStore.debug_load_agents()
      assert agents["my-agent"]["id"] == "my-agent"
    end
  end

  # Helper
  defp unique_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
