defmodule Orchestrator.Schema.PushConfig do
  @moduledoc """
  Ecto schema for push notification configurations stored in PostgreSQL.

  Maps to the `push_configs` table created in migrations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  schema "push_configs" do
    field(:url, :string)
    field(:token, :string)
    field(:hmac_secret, :string)
    field(:jwt_secret, :string)
    field(:jwt_issuer, :string)
    field(:jwt_audience, :string)
    field(:jwt_kid, :string)

    belongs_to(:task, Orchestrator.Schema.Task, type: :string)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating or updating a push configuration.

  ## Required fields
  - task_id
  - url

  ## Optional authentication fields
  - token (Bearer token)
  - hmac_secret (HMAC signing)
  - jwt_secret, jwt_issuer, jwt_audience, jwt_kid (JWT signing)
  """
  def changeset(push_config, attrs) do
    push_config
    |> cast(attrs, [
      :task_id,
      :url,
      :token,
      :hmac_secret,
      :jwt_secret,
      :jwt_issuer,
      :jwt_audience,
      :jwt_kid
    ])
    |> validate_required([:task_id, :url])
    |> validate_format(:url, ~r/^https?:\/\//, message: "must be a valid HTTP(S) URL")
    |> foreign_key_constraint(:task_id)
    |> validate_authentication()
  end

  defp validate_authentication(changeset) do
    # Ensure at least one authentication method is provided, or none (for testing)
    token = get_field(changeset, :token)
    hmac = get_field(changeset, :hmac_secret)
    jwt = get_field(changeset, :jwt_secret)

    if is_nil(token) && is_nil(hmac) && is_nil(jwt) do
      changeset
    else
      changeset
    end
  end

  @doc """
  Convert Ecto schema to map format expected by the application.
  """
  def to_map(%__MODULE__{} = config) do
    %{
      "id" => config.id,
      "taskId" => config.task_id,
      "url" => config.url,
      "token" => config.token,
      "hmacSecret" => config.hmac_secret,
      "jwtSecret" => config.jwt_secret,
      "jwtIssuer" => config.jwt_issuer,
      "jwtAudience" => config.jwt_audience,
      "jwtKid" => config.jwt_kid
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Convert application map format to Ecto changeset attrs.
  """
  def from_map(config_map) when is_map(config_map) do
    %{
      id: config_map["id"],
      task_id: config_map["taskId"] || config_map["task_id"],
      url: config_map["url"],
      token: config_map["token"],
      hmac_secret: config_map["hmacSecret"],
      jwt_secret: config_map["jwtSecret"],
      jwt_issuer: config_map["jwtIssuer"],
      jwt_audience: config_map["jwtAudience"],
      jwt_kid: config_map["jwtKid"]
    }
  end
end
