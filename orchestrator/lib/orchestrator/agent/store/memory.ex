defmodule Orchestrator.Agent.Store.Memory do
  @moduledoc """
  In-memory agent store using ETS.

  This adapter stores registered agents in an ETS table.
  Ideal for stateless deployments where agent discovery is handled externally
  (e.g., via well-known URLs or service mesh).
  """

  use GenServer

  @table :superx_agents

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register or update an agent."
  @spec put(String.t(), String.t(), map()) :: :ok
  def put(agent_id, url, opts \\ %{}) do
    agent = %{
      "id" => agent_id,
      "url" => url,
      "bearer" => Map.get(opts, "bearer") || Map.get(opts, :bearer),
      "metadata" => Map.get(opts, "metadata") || Map.get(opts, :metadata, %{}),
      "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :ets.insert(@table, {agent_id, agent})
    :ok
  end

  @doc "Get an agent by ID."
  @spec get(String.t()) :: map() | nil
  def get(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, agent}] -> agent
      [] -> nil
    end
  end

  @doc "Delete an agent by ID."
  @spec delete(String.t()) :: :ok
  def delete(agent_id) do
    :ets.delete(@table, agent_id)
    :ok
  end

  @doc "List all registered agents."
  @spec list() :: [map()]
  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, agent} -> agent end)
  end

  @doc "Find agents by URL prefix."
  @spec find_by_url(String.t()) :: [map()]
  def find_by_url(url_prefix) do
    list()
    |> Enum.filter(fn agent ->
      String.starts_with?(agent["url"] || "", url_prefix)
    end)
  end

  @doc "Find agents by metadata key-value."
  @spec find_by_metadata(String.t(), term()) :: [map()]
  def find_by_metadata(key, value) do
    list()
    |> Enum.filter(fn agent ->
      get_in(agent, ["metadata", key]) == value
    end)
  end

  # -------------------------------------------------------------------
  # Server Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
