defmodule Orchestrator.Task.PushConfig.Memory do
  @moduledoc """
  In-memory push notification config store using ETS.

  This adapter stores push configs in an ETS table.
  Ideal for stateless deployments.
  """

  use GenServer

  @table :superx_push_configs

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Store a push notification config for a task."
  @spec put(String.t(), map()) :: :ok
  def put(task_id, config) when is_map(config) do
    id = generate_id()

    push_config = %{
      "id" => id,
      "task_id" => task_id,
      "url" => config["url"],
      "token" => config["token"],
      "auth_header" => config["authHeader"] || config["auth_header"],
      "metadata" => config["metadata"] || %{},
      "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :ets.insert(@table, {id, push_config})
    :ok
  end

  @doc "Get all push configs for a task."
  @spec get_for_task(String.t()) :: [map()]
  def get_for_task(task_id) do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_id, config} -> config["task_id"] == task_id end)
    |> Enum.map(fn {_id, config} -> config end)
  end

  @doc "Get a push config by ID."
  @spec get(String.t()) :: map() | nil
  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, config}] -> config
      [] -> nil
    end
  end

  @doc "Delete a push config by ID."
  @spec delete(String.t()) :: :ok
  def delete(id) do
    :ets.delete(@table, id)
    :ok
  end

  @doc "Delete all push configs for a task."
  @spec delete_for_task(String.t()) :: :ok
  def delete_for_task(task_id) do
    get_for_task(task_id)
    |> Enum.each(fn config -> delete(config["id"]) end)

    :ok
  end

  @doc "List all push configs."
  @spec list() :: [map()]
  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, config} -> config end)
  end

  # -------------------------------------------------------------------
  # Server Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  # -------------------------------------------------------------------
  # Private Helpers
  # -------------------------------------------------------------------

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
