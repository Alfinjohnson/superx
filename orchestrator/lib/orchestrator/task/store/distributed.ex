defmodule Orchestrator.Task.Store.Distributed do
  @moduledoc """
  Distributed in-memory task store.

  Uses ETS for local storage and replicates writes across the cluster via RPC.
  Broadcasts task updates to subscribers on every node through Task.PubSub.
  """

  use GenServer

  alias Orchestrator.Task.PubSub, as: TaskPubSub
  alias Orchestrator.Task.PushConfig
  alias Orchestrator.Utils

  @table :superx_tasks
  @rpc_timeout 2_000

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Store or update a task across the cluster."
  @spec put(map()) :: :ok | {:error, term()}
  def put(%{"id" => id} = task) when is_binary(id) do
    with :ok <- ensure_not_terminal(id) do
      replicate(:put_local, [task])
      broadcast_all(id, {:task_update, task})
      PushConfig.deliver_event(id, %{"task" => task})
      :ok
    end
  end

  def put(_), do: {:error, :invalid_task}

  @doc "Get a task by ID (checks all connected nodes)."
  @spec get(String.t()) :: map() | nil
  def get(task_id) do
    nodes_with_self()
    |> Enum.find_value(fn node ->
      case safe_rpc(node, :get_local, [task_id]) do
        {:ok, task} -> task
        _ -> nil
      end
    end)
  end

  @doc "Delete a task across the cluster."
  @spec delete(String.t()) :: :ok
  def delete(task_id) do
    replicate(:delete_local, [task_id])
    broadcast_all(task_id, {:halt, :deleted})
    :ok
  end

  @doc "Subscribe to updates for a task (returns the task if present)."
  @spec subscribe(String.t()) :: map() | nil
  def subscribe(task_id) do
    case get(task_id) do
      nil ->
        nil

      task ->
        TaskPubSub.subscribe(task_id)
        task
    end
  end

  @doc "List tasks from the local node (best-effort view)."
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    @table
    |> :ets.tab2list()
    |> Enum.take(limit)
    |> Enum.map(fn {_id, task} -> task end)
  end

  @doc "Apply a status update and broadcast to the cluster."
  @spec apply_status_update(map()) :: :ok | {:error, term()}
  def apply_status_update(%{"taskId" => task_id} = update) do
    case get(task_id) do
      nil ->
        {:error, :not_found}

      task ->
        status = Map.get(update, "status") || Map.get(update, "statusUpdate") || %{}
        merged = Map.put(task, "status", status)

        case put(merged) do
          :ok ->
            broadcast_all(task_id, {:status_update, merged})
            PushConfig.deliver_event(task_id, %{"statusUpdate" => update})
            :ok

          error ->
            error
        end
    end
  end

  def apply_status_update(_), do: {:error, :invalid}

  @doc "Apply an artifact update and broadcast to the cluster."
  @spec apply_artifact_update(map()) :: :ok | {:error, term()}
  def apply_artifact_update(%{"taskId" => task_id} = update) do
    case get(task_id) do
      nil ->
        {:error, :not_found}

      task ->
        artifact =
          Map.get(update, "artifact") ||
            Map.get(update, "artifacts") ||
            Map.get(update, "artifactUpdate")

        merged = merge_artifact(task, artifact)

        case put(merged) do
          :ok ->
            broadcast_all(task_id, {:artifact_update, merged})
            PushConfig.deliver_event(task_id, %{"artifactUpdate" => update})
            :ok

          error ->
            error
        end
    end
  end

  def apply_artifact_update(_), do: {:error, :invalid}

  # -------------------------------------------------------------------
  # GenServer Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  # -------------------------------------------------------------------
  # Internal RPC targets (local operations only)
  # -------------------------------------------------------------------

  @doc false
  def put_local(%{"id" => id} = task) do
    :ets.insert(@table, {id, task})
    TaskPubSub.broadcast(id, {:task_update, task})
    :ok
  end

  @doc false
  def delete_local(task_id) do
    :ets.delete(@table, task_id)
    :ok
  end

  @doc false
  def get_local(task_id) do
    case :ets.lookup(@table, task_id) do
      [{^task_id, task}] -> task
      _ -> nil
    end
  end

  @doc false
  def broadcast_local(task_id, event) do
    TaskPubSub.broadcast(task_id, event)
    :ok
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp ensure_not_terminal(id) do
    case get(id) do
      %{"status" => %{"state" => prev_state}} ->
        if Utils.terminal_state?(prev_state) do
          {:error, :terminal}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp merge_artifact(task, nil), do: task

  defp merge_artifact(task, artifact) when is_map(artifact) do
    existing = Map.get(task, "artifacts", [])

    case find_artifact_index(existing, artifact) do
      nil -> Map.put(task, "artifacts", existing ++ [artifact])
      idx -> Map.put(task, "artifacts", List.replace_at(existing, idx, artifact))
    end
  end

  defp merge_artifact(task, artifacts) when is_list(artifacts) do
    Enum.reduce(artifacts, task, &merge_artifact(&2, &1))
  end

  defp find_artifact_index(artifacts, %{"artifactId" => id}) do
    Enum.find_index(artifacts, fn a -> a["artifactId"] == id end)
  end

  defp find_artifact_index(artifacts, %{"id" => id}) do
    Enum.find_index(artifacts, fn a -> (a["artifactId"] || a["id"]) == id end)
  end

  defp find_artifact_index(artifacts, %{"name" => name}) do
    Enum.find_index(artifacts, fn a -> a["name"] == name end)
  end

  defp find_artifact_index(_, _), do: nil

  defp nodes_with_self do
    [Node.self() | Node.list()]
  end

  defp replicate(fun, args) do
    nodes_with_self()
    |> Enum.each(fn node ->
      :rpc.cast(node, __MODULE__, fun, args)
    end)

    :ok
  end

  defp broadcast_all(task_id, event) do
    nodes_with_self()
    |> Enum.each(fn node ->
      :rpc.cast(node, __MODULE__, :broadcast_local, [task_id, event])
    end)

    :ok
  end

  defp safe_rpc(node, fun, args) do
    case :rpc.call(node, __MODULE__, fun, args, @rpc_timeout) do
      {:badrpc, _} = err -> err
      other -> {:ok, other}
    end
  end
end
