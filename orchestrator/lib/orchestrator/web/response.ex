defmodule Orchestrator.Web.Response do
  @moduledoc """
  JSON-RPC response helpers for consistent API responses.

  For error handling, use `Orchestrator.Web.RpcErrors`.
  For SSE streaming, use `Orchestrator.Web.Streaming`.
  """

  import Plug.Conn

  @doc """
  Send a successful JSON-RPC response.
  """
  @spec send_success(Plug.Conn.t(), any(), any()) :: Plug.Conn.t()
  def send_success(conn, id, result) do
    payload = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    send_resp(conn, 200, Jason.encode!(payload))
  end

  @doc """
  Send a JSON response with custom status.
  """
  @spec send_json(Plug.Conn.t(), integer(), map()) :: Plug.Conn.t()
  def send_json(conn, status, body) do
    send_resp(conn, status, Jason.encode!(body))
  end
end
