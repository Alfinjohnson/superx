defmodule Orchestrator.Web.AgentCardTest do
  @moduledoc """
  Tests for the AgentCard module which handles serving agent cards
  through the orchestrator.
  """
  use Orchestrator.ConnCase

  alias Orchestrator.Agent.Store, as: AgentStore
  alias Orchestrator.Web.AgentCard

  setup do
    # Clean up agents after each test
    on_exit(fn ->
      AgentStore.delete("card-test-agent")
      AgentStore.delete("cached-card-agent")
      AgentStore.delete("generic-card-agent")
    end)

    :ok
  end

  describe "serve/3 with cached agent card" do
    test "serves cached card from metadata with URL rewritten" do
      cached_card = %{
        "name" => "Test Agent",
        "description" => "A test agent",
        "version" => "1.0.0",
        "url" => "http://original-agent.com",
        "capabilities" => %{"streaming" => true}
      }

      agent = %{
        "id" => "cached-card-agent",
        "url" => "http://localhost:5000",
        "protocol" => "a2a",
        "protocolVersion" => "0.3.0",
        "metadata" => %{
          "agentCard" => cached_card
        }
      }

      AgentStore.upsert(agent)

      conn =
        :get
        |> conn("/agents/cached-card-agent/.well-known/agent-card.json")
        |> AgentCard.serve("cached-card-agent", agent)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)

      # URL should be rewritten to orchestrator URL
      assert response["url"] == "http://www.example.com/agents/cached-card-agent"
      assert response["name"] == "Test Agent"
      assert response["description"] == "A test agent"
    end

    test "serves card with https scheme when connection is https" do
      cached_card = %{
        "name" => "Secure Agent",
        "url" => "http://original.com"
      }

      agent = %{
        "id" => "cached-card-agent",
        "url" => "http://localhost:5000",
        "metadata" => %{"agentCard" => cached_card}
      }

      conn =
        :get
        |> conn("/agents/cached-card-agent/.well-known/agent-card.json")
        |> Map.put(:scheme, :https)
        |> Map.put(:port, 443)
        |> AgentCard.serve("cached-card-agent", agent)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert String.starts_with?(response["url"], "https://")
    end

    test "includes port in URL when non-standard" do
      cached_card = %{"name" => "Test"}

      agent = %{
        "id" => "cached-card-agent",
        "url" => "http://localhost:5000",
        "metadata" => %{"agentCard" => cached_card}
      }

      conn =
        :get
        |> conn("/agents/cached-card-agent/.well-known/agent-card.json")
        |> Map.put(:port, 8080)
        |> AgentCard.serve("cached-card-agent", agent)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["url"] =~ ":8080"
    end
  end

  describe "serve_generic/3" do
    test "serves cached card without adapter normalization" do
      cached_card = %{
        "name" => "Generic Agent",
        "custom_field" => "preserved"
      }

      agent = %{
        "id" => "generic-card-agent",
        "url" => "http://localhost:5000",
        "protocol" => "unknown-protocol",
        "metadata" => %{"agentCard" => cached_card}
      }

      conn =
        :get
        |> conn("/agents/generic-card-agent/.well-known/agent-card.json")
        |> AgentCard.serve_generic("generic-card-agent", agent)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)

      assert response["name"] == "Generic Agent"
      assert response["custom_field"] == "preserved"
      assert response["url"] == "http://www.example.com/agents/generic-card-agent"
    end
  end

  describe "serve_with_adapter/4" do
    test "normalizes card using adapter" do
      cached_card = %{
        "name" => "A2A Agent",
        "description" => "Test",
        "version" => "1.0.0",
        "url" => "http://original.com",
        "capabilities" => %{}
      }

      agent = %{
        "id" => "cached-card-agent",
        "url" => "http://localhost:5000",
        "metadata" => %{"agentCard" => cached_card}
      }

      {:ok, adapter} = Orchestrator.Protocol.adapter_for("a2a", "0.3.0")

      conn =
        :get
        |> conn("/agents/cached-card-agent/.well-known/agent-card.json")
        |> AgentCard.serve_with_adapter("cached-card-agent", agent, adapter)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["url"] == "http://www.example.com/agents/cached-card-agent"
    end
  end

  describe "fetch_and_serve/5 error handling" do
    test "returns 502 when remote agent is unreachable" do
      {:ok, adapter} = Orchestrator.Protocol.adapter_for("a2a", "0.3.0")

      # Use an unreachable URL
      conn =
        :get
        |> conn("/agents/test/.well-known/agent-card.json")
        |> AgentCard.fetch_and_serve(
          "test-agent",
          "http://localhost:59999/.well-known/agent.json",
          adapter,
          "http://orchestrator.local"
        )

      assert conn.status == 502
      response = Jason.decode!(conn.resp_body)
      assert response["error"] == "Failed to reach agent"
    end
  end

  describe "proxy_card/4 error handling" do
    test "returns 502 when card URL is unreachable" do
      conn =
        :get
        |> conn("/agents/test/.well-known/agent-card.json")
        |> AgentCard.proxy_card(
          "test-agent",
          "http://localhost:59999/.well-known/agent.json",
          "http://orchestrator.local"
        )

      assert conn.status == 502
      response = Jason.decode!(conn.resp_body)
      assert response["error"] == "Failed to reach agent"
    end
  end

  describe "integration via router" do
    test "GET /agents/:id/.well-known/agent-card.json serves card" do
      cached_card = %{
        "name" => "Router Test Agent",
        "description" => "Test",
        "version" => "1.0.0",
        "url" => "http://original.com",
        "capabilities" => %{}
      }

      AgentStore.upsert(%{
        "id" => "card-test-agent",
        "url" => "http://localhost:5000",
        "metadata" => %{"agentCard" => cached_card}
      })

      conn =
        :get
        |> conn("/agents/card-test-agent/.well-known/agent-card.json")
        |> Orchestrator.Router.call(Orchestrator.Router.init([]))

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["name"] == "Router Test Agent"
    end

    test "GET /agents/:id/.well-known/agent-card.json returns 404 for missing agent" do
      conn =
        :get
        |> conn("/agents/non-existent-agent/.well-known/agent-card.json")
        |> Orchestrator.Router.call(Orchestrator.Router.init([]))

      assert conn.status == 404
    end
  end
end
