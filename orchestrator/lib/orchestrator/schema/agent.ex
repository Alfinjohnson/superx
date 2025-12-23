defmodule Orchestrator.Schema.Agent do
  @moduledoc """
  Ecto schema for persisted agent configurations.

  ## Fields

  - `id` - Unique agent identifier (string)
  - `url` - Agent's A2A endpoint URL
  - `bearer` - Optional bearer token for authentication
  - `metadata` - JSON metadata including agent card

  ## Metadata Structure

  The metadata field typically contains:

      %{
        "agentCard" => %{...},       # Cached agent card
        "protocol" => "a2a",          # Protocol type
        "protocolVersion" => "0.3.0"  # Protocol version
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Orchestrator.Utils

  @type t :: %__MODULE__{
          id: String.t(),
          url: String.t(),
          bearer: String.t() | nil,
          metadata: map() | nil,
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "agents" do
    field(:url, :string)
    field(:bearer, :string)
    field(:metadata, :map)
    timestamps()
  end

  @required_fields ~w(id url)a
  @optional_fields ~w(bearer metadata)a

  @doc """
  Create a changeset for agent creation/update.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_url(:url)
  end

  @doc """
  Convert an Agent schema to a map suitable for API responses.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = agent) do
    %{
      "id" => agent.id,
      "url" => agent.url
    }
    |> Utils.maybe_put("bearer", agent.bearer)
    |> Utils.maybe_put("metadata", agent.metadata)
  end

  # Validate URL format
  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      case URI.parse(value) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
          []

        _ ->
          [{field, "must be a valid HTTP(S) URL"}]
      end
    end)
  end
end

# Backward compatibility alias
defmodule Orchestrator.AgentRecord do
  @moduledoc false
  defdelegate changeset(struct, attrs), to: Orchestrator.Schema.Agent
  defdelegate to_map(agent), to: Orchestrator.Schema.Agent
end
