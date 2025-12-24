defmodule Orchestrator.Web.Handlers.Agent do
  @moduledoc """
  Handles agents.* JSON-RPC methods.

  Provides CRUD operations for agent management and health checks.
  """

  alias Orchestrator.Agent.Store, as: AgentStore
  alias Orchestrator.Agent.Worker, as: AgentWorker
  alias Orchestrator.Web.RpcErrors
  alias Orchestrator.Web.Response

  @doc """
  Handle agents.list - returns all registered agents.
  """
  @spec handle_list(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def handle_list(conn, id) do
    agents = AgentStore.list()
    Response.send_success(conn, id, agents)
  end

  @doc """
  Handle agents.get - returns a single agent by ID.
  """
  @spec handle_get(Plug.Conn.t(), any(), String.t()) :: Plug.Conn.t()
  def handle_get(conn, id, agent_id) do
    case AgentStore.fetch(agent_id) do
      nil ->
        RpcErrors.send_error(conn, id, RpcErrors.code(:resource_not_found), "Agent not found")

      agent ->
        Response.send_success(conn, id, agent)
    end
  end

  @doc """
  Handle agents.upsert - creates or updates an agent.
  """
  @spec handle_upsert(Plug.Conn.t(), any(), map()) :: Plug.Conn.t()
  def handle_upsert(conn, id, agent) do
    case AgentStore.upsert(agent) do
      {:ok, stored} ->
        Response.send_success(conn, id, stored)

      {:error, :invalid} ->
        RpcErrors.send_error(
          conn,
          id,
          RpcErrors.code(:invalid_params),
          "Invalid agent payload (id and url required)"
        )
    end
  end

  @doc """
  Handle agents.delete - removes an agent by ID.
  """
  @spec handle_delete(Plug.Conn.t(), any(), String.t()) :: Plug.Conn.t()
  def handle_delete(conn, id, agent_id) do
    AgentStore.delete(agent_id)
    Response.send_success(conn, id, true)
  end

  @doc """
  Handle agents.refreshCard - not implemented in memory-only mode.
  """
  @spec handle_refresh_card(Plug.Conn.t(), any(), String.t()) :: Plug.Conn.t()
  def handle_refresh_card(conn, id, _agent_id) do
    RpcErrors.send_error(
      conn,
      id,
      RpcErrors.code(:method_not_found),
      "agents.refreshCard not implemented in memory-only mode"
    )
  end

  @doc """
  Handle agents.health - returns health status for a specific agent.
  """
  @spec handle_health(Plug.Conn.t(), any(), String.t()) :: Plug.Conn.t()
  def handle_health(conn, id, agent_id) do
    case AgentWorker.health(agent_id) do
      {:ok, health} ->
        Response.send_success(conn, id, health)

      {:error, :agent_not_found} ->
        RpcErrors.send_error(conn, id, RpcErrors.code(:resource_not_found), "Agent not found")
    end
  end

  @doc """
  Handle agents.health (all) - returns health status for all agents.
  """
  @spec handle_health_all(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def handle_health_all(conn, id) do
    agents = AgentStore.list()

    healths =
      Enum.map(agents, fn agent ->
        case AgentWorker.health(agent["id"]) do
          {:ok, h} -> h
          {:error, _} -> %{agent_id: agent["id"], breaker_state: :unknown}
        end
      end)

    Response.send_success(conn, id, healths)
  end
end
