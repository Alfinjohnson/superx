defmodule Orchestrator.Agent.Store.Postgres do
  @moduledoc """
  PostgreSQL agent store using Ecto.

  This adapter stores agent configurations in PostgreSQL for persistence
  and horizontal scaling with shared database.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Orchestrator.Repo
  alias Orchestrator.Schema.Agent, as: AgentSchema
  alias Orchestrator.Infra.HttpClient

  @doc "Register or update an agent."
  @spec put(String.t(), String.t(), map()) :: :ok
  def put(agent_id, url, opts \\ %{}) do
    attrs = %{
      id: agent_id,
      url: url,
      bearer: Map.get(opts, "bearer") || Map.get(opts, :bearer),
      metadata: Map.get(opts, "metadata") || Map.get(opts, :metadata, %{})
    }

    changeset = AgentSchema.changeset(%AgentSchema{}, attrs)

    conflict_updates = [
      set: [
        url: attrs.url,
        bearer: attrs.bearer,
        metadata: attrs.metadata,
        updated_at: NaiveDateTime.utc_now()
      ]
    ]

    Repo.insert(changeset, on_conflict: conflict_updates, conflict_target: :id)
    :ok
  end

  @doc "Get an agent by ID."
  @spec get(String.t()) :: map() | nil
  def get(agent_id) do
    case Repo.get(AgentSchema, agent_id) do
      nil -> nil
      record -> AgentSchema.to_map(record)
    end
  end

  @doc "Delete an agent by ID."
  @spec delete(String.t()) :: :ok
  def delete(agent_id) do
    Repo.delete_all(from(a in AgentSchema, where: a.id == ^agent_id))
    :ok
  end

  @doc "List all registered agents."
  @spec list() :: [map()]
  def list do
    AgentSchema
    |> Ecto.Query.order_by([a], asc: a.id)
    |> Repo.all()
    |> Enum.map(&AgentSchema.to_map/1)
  end

  @doc "Find agents by URL prefix."
  @spec find_by_url(String.t()) :: [map()]
  def find_by_url(url_prefix) do
    pattern = "#{url_prefix}%"

    AgentSchema
    |> Ecto.Query.where([a], like(a.url, ^pattern))
    |> Repo.all()
    |> Enum.map(&AgentSchema.to_map/1)
  end

  @doc "Find agents by metadata key-value (using JSONB query)."
  @spec find_by_metadata(String.t(), term()) :: [map()]
  def find_by_metadata(key, value) do
    AgentSchema
    |> Ecto.Query.where([a], fragment("metadata->>? = ?", ^key, ^value))
    |> Repo.all()
    |> Enum.map(&AgentSchema.to_map/1)
  end

  @doc "Fetch and update agent card from remote URL."
  @spec refresh_card(String.t()) :: {:ok, map()} | {:error, term()}
  def refresh_card(agent_id) do
    case get(agent_id) do
      nil ->
        {:error, :not_found}

      agent ->
        with {:ok, card_url} <- resolve_card_url(agent),
             {:ok, card} <- HttpClient.fetch_agent_card(card_url) do
          metadata =
            (agent["metadata"] || %{})
            |> Map.put("agentCard", card)
            |> Map.put("card_url", card_url)

          put(agent_id, agent["url"], %{"bearer" => agent["bearer"], "metadata" => metadata})
          {:ok, Map.put(agent, "metadata", metadata)}
        end
    end
  end

  # -------------------------------------------------------------------
  # Private Helpers
  # -------------------------------------------------------------------

  defp resolve_card_url(%{"metadata" => %{"card_url" => url}}) when is_binary(url) do
    {:ok, url}
  end

  defp resolve_card_url(%{"url" => base}) when is_binary(base) do
    case URI.parse(base) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        url =
          %URI{uri | path: "/.well-known/agent-card.json", query: nil, fragment: nil}
          |> URI.to_string()

        {:ok, url}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp resolve_card_url(_), do: {:error, :invalid_url}
end
