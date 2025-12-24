defmodule Orchestrator.Web.AgentCard do
  @moduledoc """
  Handles serving agent cards through the orchestrator.

  Agent cards are JSON documents describing an agent's capabilities,
  following the A2A protocol specification. This module handles:
  - Serving cached cards from agent metadata
  - Fetching cards from remote URLs
  - Protocol-specific card normalization
  - Rewriting card URLs to route through the orchestrator
  - **Synthesizing cards for MCP servers** from tools/resources/prompts
  """

  import Plug.Conn
  require Logger

  alias Orchestrator.MCP.Supervisor, as: MCPSupervisor
  alias Orchestrator.MCP.Session, as: MCPSession

  @doc """
  Serve an agent's card, handling protocol detection and card resolution.
  """
  @spec serve(Plug.Conn.t(), String.t(), map()) :: Plug.Conn.t()
  def serve(conn, agent_id, agent) do
    protocol = agent["protocol"] || "a2a"
    protocol_version = agent["protocolVersion"] || "0.3.0"

    # MCP agents get synthesized cards from the session
    if protocol == "mcp" do
      serve_mcp_card(conn, agent_id, agent)
    else
      # Use protocol-specific card handling for A2A and others
      case Orchestrator.Protocol.adapter_for(protocol, protocol_version) do
        {:ok, adapter} ->
          serve_with_adapter(conn, agent_id, agent, adapter)

        {:error, _} ->
          # Fallback for unknown protocols - try generic card serving
          serve_generic(conn, agent_id, agent)
      end
    end
  end

  @doc """
  Serve a synthesized agent card for MCP servers.

  MCP servers don't have a `.well-known/agent-card.json` endpoint,
  so we synthesize one from the session's tools, resources, and prompts.
  """
  @spec serve_mcp_card(Plug.Conn.t(), String.t(), map()) :: Plug.Conn.t()
  def serve_mcp_card(conn, agent_id, _agent) do
    orchestrator_url = get_orchestrator_url(conn)

    case MCPSupervisor.lookup_session(agent_id) do
      {:ok, session} ->
        case MCPSession.get_agent_card(session) do
          {:ok, card} ->
            # Add orchestrator URL for routing
            card = Map.put(card, "url", "#{orchestrator_url}/agents/#{agent_id}")
            send_resp(conn, 200, Jason.encode!(card))

          {:error, {:not_ready, state}} ->
            send_resp(
              conn,
              503,
              Jason.encode!(%{
                error: "MCP session not ready",
                state: to_string(state),
                message: "Try again after session initializes"
              })
            )

          {:error, reason} ->
            Logger.warning("Failed to get MCP agent card: #{inspect(reason)}")
            send_resp(conn, 500, Jason.encode!(%{error: "Failed to build agent card"}))
        end

      :error ->
        send_resp(
          conn,
          503,
          Jason.encode!(%{
            error: "MCP session not found",
            message: "MCP server may not be running"
          })
        )
    end
  end

  @doc """
  Serve a card using a protocol adapter for normalization.
  """
  @spec serve_with_adapter(Plug.Conn.t(), String.t(), map(), module()) :: Plug.Conn.t()
  def serve_with_adapter(conn, agent_id, agent, adapter) do
    orchestrator_url = get_orchestrator_url(conn)
    cached_card = get_in(agent, ["metadata", "agentCard"])

    cond do
      # 1. Check if we have a valid cached card with required fields
      cached_card != nil and adapter.valid_card?(cached_card) ->
        card =
          cached_card
          |> adapter.normalize_agent_card()
          |> Map.put("url", "#{orchestrator_url}/agents/#{agent_id}")

        send_resp(conn, 200, Jason.encode!(card))

      # 2. Check if there's an explicit card URL to fetch from
      true ->
        card_url = adapter.resolve_card_url(agent)
        fetch_and_serve(conn, agent_id, card_url, adapter, orchestrator_url)
    end
  end

  @doc """
  Serve a card without protocol-specific handling.
  """
  @spec serve_generic(Plug.Conn.t(), String.t(), map()) :: Plug.Conn.t()
  def serve_generic(conn, agent_id, agent) do
    orchestrator_url = get_orchestrator_url(conn)
    cached_card = get_in(agent, ["metadata", "agentCard"])

    if cached_card != nil do
      card = Map.put(cached_card, "url", "#{orchestrator_url}/agents/#{agent_id}")
      send_resp(conn, 200, Jason.encode!(card))
    else
      # Fallback to well-known path
      card_url = "#{agent["url"]}/.well-known/agent.json"
      proxy_card(conn, agent_id, card_url, orchestrator_url)
    end
  end

  @doc """
  Fetch a card from a remote URL and serve it with adapter normalization.
  """
  @spec fetch_and_serve(Plug.Conn.t(), String.t(), String.t(), module(), String.t()) ::
          Plug.Conn.t()
  def fetch_and_serve(conn, agent_id, card_url, adapter, orchestrator_url) do
    case Req.get(card_url, finch: Orchestrator.Finch, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        card =
          body
          |> adapter.normalize_agent_card()
          |> Map.put("url", "#{orchestrator_url}/agents/#{agent_id}")

        send_resp(conn, 200, Jason.encode!(card))

      {:ok, %{status: status}} ->
        send_resp(
          conn,
          status,
          Jason.encode!(%{error: "Failed to fetch agent card", status: status})
        )

      {:error, reason} ->
        Logger.warning("Failed to fetch agent card from #{card_url}: #{inspect(reason)}")
        send_resp(conn, 502, Jason.encode!(%{error: "Failed to reach agent"}))
    end
  end

  @doc """
  Proxy a card request without adapter normalization.
  """
  @spec proxy_card(Plug.Conn.t(), String.t(), String.t(), String.t()) :: Plug.Conn.t()
  def proxy_card(conn, agent_id, card_url, orchestrator_url) do
    case Req.get(card_url, finch: Orchestrator.Finch, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        card = Map.put(body, "url", "#{orchestrator_url}/agents/#{agent_id}")
        send_resp(conn, 200, Jason.encode!(card))

      {:ok, %{status: status}} ->
        send_resp(conn, status, Jason.encode!(%{error: "Failed to fetch agent card"}))

      {:error, _} ->
        send_resp(conn, 502, Jason.encode!(%{error: "Failed to reach agent"}))
    end
  end

  # -------------------------------------------------------------------
  # Private Helpers
  # -------------------------------------------------------------------

  defp get_orchestrator_url(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    host = conn.host
    port = conn.port

    if (scheme == "http" and port == 80) or (scheme == "https" and port == 443) do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end
end
