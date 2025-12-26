defmodule Orchestrator.Web.Streaming do
  @moduledoc """
  Server-Sent Events (SSE) streaming utilities.

  Provides helpers for initializing SSE connections, sending events,
  and managing long-running event loops for task subscriptions.
  """

  import Plug.Conn

  alias Orchestrator.Utils

  # -------------------------------------------------------------------
  # SSE Connection Setup
  # -------------------------------------------------------------------

  @doc """
  Initialize an SSE connection with proper headers.
  """
  @spec init_sse(Plug.Conn.t()) :: Plug.Conn.t()
  def init_sse(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
  end

  # -------------------------------------------------------------------
  # SSE Event Sending
  # -------------------------------------------------------------------

  @doc """
  Send an SSE event with JSON data.
  """
  @spec send_event(Plug.Conn.t(), map()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def send_event(conn, data) do
    json = Jason.encode!(data)
    chunk(conn, "data: " <> json <> "\n\n")
  end

  @doc """
  Send an SSE keep-alive comment to prevent idle timeouts.
  """
  @spec send_keepalive(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def send_keepalive(conn) do
    chunk(conn, ": keep-alive\n\n")
  end

  # -------------------------------------------------------------------
  # Task Event Loop
  # -------------------------------------------------------------------

  @doc """
  Stream task updates to the client via SSE.

  Sends initial task state, then loops waiting for updates until
  the task reaches a terminal state or the connection closes.
  """
  @spec stream_task(Plug.Conn.t(), any(), map()) :: Plug.Conn.t()
  def stream_task(conn, rpc_id, initial_task) do
    conn = init_sse(conn)
    {:ok, conn} = send_event(conn, %{jsonrpc: "2.0", id: rpc_id, result: initial_task})
    task_id = initial_task["id"]
    loop_task_events(conn, rpc_id, task_id)
  end

  @doc """
  Event loop for task subscription streaming.

  Waits for task updates and sends them as SSE events.
  Terminates when task reaches a terminal state or receives halt signal.
  Sends keep-alive comments every 15 seconds to prevent idle timeouts.
  """
  @spec loop_task_events(Plug.Conn.t(), any(), String.t()) :: Plug.Conn.t()
  def loop_task_events(conn, rpc_id, task_id) do
    receive do
      {update_type, task} when update_type in [:task_update, :status_update, :artifact_update] ->
        {:ok, conn} = send_event(conn, %{jsonrpc: "2.0", id: rpc_id, result: task})

        if Utils.terminal_state?(get_in(task, ["status", "state"])) do
          halt(conn)
        else
          loop_task_events(conn, rpc_id, task_id)
        end

      {:halt, _} ->
        halt(conn)
    after
      15_000 ->
        {:ok, conn} = send_keepalive(conn)
        loop_task_events(conn, rpc_id, task_id)
    end
  end
end
