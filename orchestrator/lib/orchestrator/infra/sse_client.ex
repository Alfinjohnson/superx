defmodule Orchestrator.Infra.SSEClient do
  @moduledoc """
  Server-Sent Events (SSE) client for consuming streaming responses.

  Handles A2A protocol streaming responses (message/stream) and dispatches
  updates to the task store.

  ## Protocol

  The upstream server sends newline-delimited JSON events:

      data: {"result": {"statusUpdate": {"taskId": "...", "status": {...}}}}

      data: {"result": {"artifactUpdate": {"taskId": "...", "artifact": {...}}}}

      data: {"result": {"task": {...}}}

  ## Usage

      {:ok, pid} = Orchestrator.Infra.SSEClient.start_link(
        url: "http://agent.local/a2a",
        payload: %{"jsonrpc" => "2.0", "method" => "message/stream", ...},
        headers: [{"content-type", "application/json"}],
        reply_to: self(),
        rpc_id: "req-123"
      )

      # Receive initial result
      receive do
        {:stream_init, "req-123", result} -> handle_init(result)
        {:stream_error, "req-123", status} -> handle_error(status)
      end
  """

  require Logger

  alias Orchestrator.Task.Store, as: TaskStore
  alias Orchestrator.Utils

  @doc """
  Start an SSE client to consume a streaming response.

  ## Options

  - `:url` - The URL to POST to (required)
  - `:payload` - The JSON-RPC request body (required)
  - `:headers` - HTTP headers (default: [])
  - `:reply_to` - Process to notify on init/error (required)
  - `:rpc_id` - JSON-RPC request ID for correlation (required)
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) do
    Task.start_link(fn -> run(opts) end)
  end

  # ---- Internal ----

  defp run(opts) do
    url = Keyword.fetch!(opts, :url)
    headers = Keyword.get(opts, :headers, [])
    payload = Keyword.fetch!(opts, :payload)
    reply_to = Keyword.fetch!(opts, :reply_to)
    rpc_id = Keyword.fetch!(opts, :rpc_id)

    req = Finch.build(:post, url, headers, Jason.encode!(payload))

    initial_state = %{
      buffer: "",
      sent_init: false,
      reply_to: reply_to,
      rpc_id: rpc_id
    }

    case Finch.stream(req, Orchestrator.Finch, initial_state, &handle_chunk/2) do
      {:ok, _} ->
        :ok

      {:error, %Mint.TransportError{reason: reason}, state} ->
        Logger.warning("SSE client transport error", reason: inspect(reason), rpc_id: rpc_id)
        send(state.reply_to, {:stream_error, state.rpc_id, {:transport_error, reason}})

      {:error, reason, state} ->
        Logger.warning("SSE client failed with state", reason: inspect(reason), rpc_id: rpc_id)
        send(state.reply_to, {:stream_error, state.rpc_id, reason})

      {:error, reason} ->
        Logger.warning("SSE client failed", reason: inspect(reason), rpc_id: rpc_id)
        send(reply_to, {:stream_error, rpc_id, reason})
    end
  end

  defp handle_chunk({:status, status}, state) do
    if status in 200..299 do
      {:cont, state}
    else
      send(state.reply_to, {:stream_error, state.rpc_id, status})
      {:halt, state}
    end
  end

  defp handle_chunk({:headers, _headers}, state), do: {:cont, state}

  defp handle_chunk({:data, chunk}, state) do
    data = state.buffer <> IO.iodata_to_binary(chunk)
    {events, rest} = split_events(data)

    new_state =
      Enum.reduce(events, state, fn ev, acc ->
        case handle_event(ev, acc) do
          {:ok, acc2} ->
            acc2

          {:init, result, acc2} ->
            unless acc2.sent_init do
              send(acc2.reply_to, {:stream_init, acc2.rpc_id, result})
            end

            %{acc2 | sent_init: true}

          {:error, acc2} ->
            acc2
        end
      end)

    {:cont, %{new_state | buffer: rest}}
  end

  defp handle_chunk(:done, state) do
    {:halt, state}
  end

  defp split_events(data) do
    parts = String.split(data, "\n\n")
    {Enum.slice(parts, 0, length(parts) - 1), List.last(parts)}
  end

  defp handle_event("", state), do: {:ok, state}

  defp handle_event(event, state) do
    body = event |> String.replace_prefix("data: ", "") |> String.trim()

    with {:ok, decoded} <- Jason.decode(body),
         %{"result" => result} <- decoded do
      dispatch_result(result)

      case state.sent_init do
        false -> {:init, result, state}
        true -> {:ok, state}
      end
    else
      _ -> {:error, state}
    end
  end

  defp dispatch_result(%{"statusUpdate" => update}) do
    TaskStore.apply_status_update(update)
  end

  defp dispatch_result(%{"artifactUpdate" => update}) do
    TaskStore.apply_artifact_update(update)
  end

  defp dispatch_result(%{"task" => task}) do
    TaskStore.put(task)
  end

  defp dispatch_result(%{"message" => message}) do
    task = %{
      "id" => message["id"] || Utils.new_id(),
      "message" => message,
      "status" => %{"state" => "completed"}
    }

    TaskStore.put(task)
  end

  defp dispatch_result(_), do: :ok
end

# Backward compatibility alias
defmodule Orchestrator.StreamClient do
  @moduledoc false
  defdelegate start_link(opts), to: Orchestrator.Infra.SSEClient
end
