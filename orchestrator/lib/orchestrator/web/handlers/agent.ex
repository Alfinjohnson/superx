defmodule Orchestrator.Web.Handlers.Agent do
  @moduledoc """
  Handles agents.* JSON-RPC methods.

  Provides CRUD operations for agent management and health checks.
  """

  alias Orchestrator.Agent.Store, as: AgentStore
  alias Orchestrator.Agent.Worker, as: AgentWorker
  alias Orchestrator.Web.RpcErrors
  alias Orchestrator.Web.Response

  # -------------------------------------------------------------------
  # CRUD Operations
  # -------------------------------------------------------------------

  @doc "Handle agents.list - returns all registered agents."
  @spec handle_list(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def handle_list(conn, id) do
    Response.send_success(conn, id, AgentStore.list())
  end

  @doc "Handle agents.get - returns a single agent by ID."
  @spec handle_get(Plug.Conn.t(), any(), String.t()) :: Plug.Conn.t()
  def handle_get(conn, id, agent_id) do
    AgentStore.fetch(agent_id)
    |> send_or_error(conn, id, "Agent not found", :resource_not_found)
  end

  @doc "Handle agents.upsert - creates or updates an agent."
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

  @doc "Handle agents.delete - removes an agent by ID."
  @spec handle_delete(Plug.Conn.t(), any(), String.t()) :: Plug.Conn.t()
  def handle_delete(conn, id, agent_id) do
    AgentStore.delete(agent_id)
    Response.send_success(conn, id, true)
  end

  # -------------------------------------------------------------------
  # Health & Management
  # -------------------------------------------------------------------

  @doc "Handle agents.refreshCard - not implemented in memory-only mode."
  @spec handle_refresh_card(Plug.Conn.t(), any(), String.t()) :: Plug.Conn.t()
  def handle_refresh_card(conn, id, _agent_id) do
    RpcErrors.send_error(
      conn,
      id,
      RpcErrors.code(:method_not_found),
      "agents.refreshCard not implemented in memory-only mode"
    )
  end

  @doc "Handle agents.health - returns health status for a specific agent."
  @spec handle_health(Plug.Conn.t(), any(), String.t()) :: Plug.Conn.t()
  def handle_health(conn, id, agent_id) do
    AgentWorker.health(agent_id)
    |> send_result_or_error(conn, id, "Agent not found", :resource_not_found)
  end

  @doc "Handle agents.health (all) - returns health status for all agents."
  @spec handle_health_all(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def handle_health_all(conn, id) do
    healths =
      AgentStore.list()
      |> Enum.map(&fetch_health/1)

    Response.send_success(conn, id, healths)
  end

  # -------------------------------------------------------------------
  # Private Helpers
  # -------------------------------------------------------------------

  # Send success if value exists, error otherwise
  defp send_or_error(nil, conn, id, msg, code) do
    RpcErrors.send_error(conn, id, RpcErrors.code(code), msg)
  end

  defp send_or_error(value, conn, id, _msg, _code) do
    Response.send_success(conn, id, value)
  end

  # Send success for {:ok, result}, error for {:error, _}
  defp send_result_or_error({:ok, result}, conn, id, _msg, _code) do
    Response.send_success(conn, id, result)
  end

  defp send_result_or_error({:error, :agent_not_found}, conn, id, msg, code) do
    RpcErrors.send_error(conn, id, RpcErrors.code(code), msg)
  end

  # Fetch health for an agent, with fallback for missing agents
  defp fetch_health(%{"id" => id}) do
    case AgentWorker.health(id) do
      {:ok, health} -> health
      {:error, _} -> %{agent_id: id, breaker_state: :unknown}
    end
  end
end
