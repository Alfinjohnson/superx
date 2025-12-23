defmodule Orchestrator.Schema.PushConfig do
  @moduledoc """
  Ecto schema for task push notification configurations.

  ## Fields

  - `id` - Push config ID
  - `task_id` - Associated task ID
  - `url` - Webhook URL to receive notifications
  - `token` - Bearer token for authentication
  - `hmac_secret` - Secret for HMAC signature
  - `jwt_secret` - Secret for JWT signing
  - `jwt_issuer` - JWT issuer claim
  - `jwt_audience` - JWT audience claim
  - `jwt_kid` - JWT key ID
  - `authentication` - Authentication configuration map

  ## Authentication Types

  The `authentication` field can specify different auth methods:

      # Bearer token
      %{"type" => "bearer", "token" => "..."}

      # HMAC signature
      %{"type" => "hmac", "secret" => "..."}

      # JWT
      %{"type" => "jwt", "secret" => "...", "issuer" => "...", "audience" => "..."}
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Orchestrator.Utils

  @type t :: %__MODULE__{
          id: String.t(),
          task_id: String.t(),
          url: String.t(),
          token: String.t() | nil,
          hmac_secret: String.t() | nil,
          jwt_secret: String.t() | nil,
          jwt_issuer: String.t() | nil,
          jwt_audience: String.t() | nil,
          jwt_kid: String.t() | nil,
          authentication: map() | nil,
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "push_configs" do
    field :task_id, :string
    field :url, :string
    field :token, :string
    field :hmac_secret, :string
    field :jwt_secret, :string
    field :jwt_issuer, :string
    field :jwt_audience, :string
    field :jwt_kid, :string
    field :authentication, :map

    timestamps()
  end

  @required_fields ~w(id task_id url)a
  @optional_fields ~w(token authentication hmac_secret jwt_secret jwt_issuer jwt_audience jwt_kid)a

  @doc """
  Create a changeset for push config creation/update.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end

  @doc """
  Convert a PushConfig schema to a map suitable for API responses.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    base = %{
      "id" => config.id,
      "taskId" => config.task_id,
      "url" => config.url
    }

    base
    |> Utils.maybe_put("token", config.token)
    |> Utils.maybe_put("authentication", config.authentication)
  end
end

# Backward compatibility alias
defmodule Orchestrator.PushConfigRecord do
  @moduledoc false
  defdelegate changeset(struct, attrs), to: Orchestrator.Schema.PushConfig
  defdelegate to_map(config), to: Orchestrator.Schema.PushConfig
end
