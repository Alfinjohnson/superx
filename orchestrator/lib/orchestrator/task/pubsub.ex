defmodule Orchestrator.Task.PubSub do
  @moduledoc """
  Task subscription and broadcast system.

  Allows processes to subscribe to task updates and receive notifications
  when tasks are modified.

  ## Usage

      # Subscribe to task updates
      Task.PubSub.subscribe("task-123")

      # Receive updates in your process
      receive do
        {:task_update, task} -> handle_update(task)
        {:status_update, task} -> handle_status(task)
        {:artifact_update, task} -> handle_artifact(task)
      end

      # Broadcast an update
      Task.PubSub.broadcast("task-123", {:task_update, task})
  """

  use GenServer

  require Logger

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe the calling process to task updates.

  The subscribing process will receive messages in the format:
  - `{:task_update, task}` - Full task update
  - `{:status_update, task}` - Status change
  - `{:artifact_update, task}` - Artifact change
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(task_id) do
    GenServer.call(__MODULE__, {:subscribe, task_id, self()})
  end

  @doc "Unsubscribe the calling process from task updates."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(task_id) do
    GenServer.call(__MODULE__, {:unsubscribe, task_id, self()})
  end

  @doc "Broadcast an event to all subscribers of a task."
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(task_id, event) do
    GenServer.cast(__MODULE__, {:broadcast, task_id, event})
  end

  @doc "Get count of subscribers for a task."
  @spec subscriber_count(String.t()) :: non_neg_integer()
  def subscriber_count(task_id) do
    GenServer.call(__MODULE__, {:count, task_id})
  end

  # -------------------------------------------------------------------
  # Server Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # State: %{task_id => MapSet.new([pid, ...])}
    {:ok, %{subscriptions: %{}}}
  end

  @impl true
  def handle_call({:subscribe, task_id, pid}, _from, state) do
    # Monitor the subscriber to clean up on exit
    Process.monitor(pid)

    subs =
      Map.update(
        state.subscriptions,
        task_id,
        MapSet.new([pid]),
        &MapSet.put(&1, pid)
      )

    {:reply, :ok, %{state | subscriptions: subs}}
  end

  @impl true
  def handle_call({:unsubscribe, task_id, pid}, _from, state) do
    subs =
      Map.update(
        state.subscriptions,
        task_id,
        MapSet.new(),
        &MapSet.delete(&1, pid)
      )

    # Remove empty task entries
    subs =
      if MapSet.size(Map.get(subs, task_id, MapSet.new())) == 0 do
        Map.delete(subs, task_id)
      else
        subs
      end

    {:reply, :ok, %{state | subscriptions: subs}}
  end

  @impl true
  def handle_call({:count, task_id}, _from, state) do
    count =
      state.subscriptions
      |> Map.get(task_id, MapSet.new())
      |> MapSet.size()

    {:reply, count, state}
  end

  @impl true
  def handle_cast({:broadcast, task_id, event}, state) do
    subscribers = Map.get(state.subscriptions, task_id, MapSet.new())

    Enum.each(subscribers, fn pid ->
      send(pid, event)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Remove dead subscriber from all tasks
    subs =
      Map.new(state.subscriptions, fn {task_id, pids} ->
        {task_id, MapSet.delete(pids, pid)}
      end)
      |> Enum.reject(fn {_task_id, pids} -> MapSet.size(pids) == 0 end)
      |> Map.new()

    {:noreply, %{state | subscriptions: subs}}
  end
end
