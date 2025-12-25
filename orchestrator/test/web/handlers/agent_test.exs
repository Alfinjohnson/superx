defmodule Orchestrator.Web.Handlers.AgentTest do
  @moduledoc """
  Tests for Agent handlers - agents.* JSON-RPC methods via Router.
  """
  use Orchestrator.ConnCase, async: false

  alias Orchestrator.Agent.Store, as: AgentStore

  setup do
    agent_id = "handler-test-agent-#{:rand.uniform(100_000)}"

    on_exit(fn ->
      AgentStore.delete(agent_id)
    end)

    {:ok, agent_id: agent_id}
  end

  describe "agents.list" do
    test "returns list of agents" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "agents.list",
        "params" => %{}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert is_list(response["result"])
    end
  end

  describe "agents.get" do
    test "returns agent when found", %{agent_id: agent_id} do
      # First create the agent
      AgentStore.upsert(%{"id" => agent_id, "url" => "http://localhost:8000"})

      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "agents.get",
        "params" => %{"id" => agent_id}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["result"]["id"] == agent_id
    end

    test "returns error when agent not found" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "agents.get",
        "params" => %{"id" => "nonexistent-#{:rand.uniform(100_000)}"}
      }

      conn = json_post("/rpc", request)

      # Router returns 400 for errors
      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"]["message"] =~ "not found"
    end
  end

  describe "agents.upsert" do
    test "creates a new agent", %{agent_id: agent_id} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "agents.upsert",
        "params" => %{
          "agent" => %{
            "id" => agent_id,
            "url" => "http://localhost:9000"
          }
        }
      }

      conn = json_post("/rpc", request)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["result"]["id"] == agent_id
    end

    test "returns error for invalid agent" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "agents.upsert",
        "params" => %{"agent" => %{}}
      }

      conn = json_post("/rpc", request)

      # Router returns 400 for invalid params
      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"]["message"] =~ "Invalid"
    end
  end

  describe "agents.delete" do
    test "deletes an agent", %{agent_id: agent_id} do
      # First create the agent
      AgentStore.upsert(%{"id" => agent_id, "url" => "http://localhost:8000"})

      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "agents.delete",
        "params" => %{"id" => agent_id}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["result"] == true
    end
  end

  describe "agents.refreshCard" do
    test "returns not implemented error" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "agents.refreshCard",
        "params" => %{"id" => "some-agent"}
      }

      conn = json_post("/rpc", request)

      # Returns error for not implemented
      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"]["message"] =~ "not implemented"
    end
  end

  describe "agents.health" do
    test "returns health for agent", %{agent_id: agent_id} do
      # Create an agent
      AgentStore.upsert(%{"id" => agent_id, "url" => "http://localhost:8000"})

      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "agents.health",
        "params" => %{"id" => agent_id}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert is_map(response["result"])
    end

    test "returns error for non-existent agent" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "agents.health",
        "params" => %{"id" => "nonexistent-agent-#{:rand.uniform(100_000)}"}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"]["message"] =~ "not found"
    end

    test "returns health for all agents when no id" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "agents.health",
        "params" => %{}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert is_list(response["result"])
    end
  end
end
