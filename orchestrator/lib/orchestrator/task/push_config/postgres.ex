defmodule Orchestrator.Task.PushConfig.Postgres do
  @moduledoc """
  PostgreSQL push notification config store using Ecto.

  This adapter stores push notification configs in PostgreSQL for persistence.
  """

  import Ecto.Query, only: [from: 2]

  alias Orchestrator.{Repo, Utils}
  alias Orchestrator.Schema.PushConfig, as: PushConfigSchema

  @doc "Store a push notification config for a task."
  @spec put(String.t(), map()) :: :ok
  def put(task_id, params) when is_binary(task_id) and is_map(params) do
    cfg = build_config(task_id, params)
    changeset = PushConfigSchema.changeset(%PushConfigSchema{}, cfg)
    Repo.insert(changeset)
    :ok
  end

  @doc "Get all push configs for a task."
  @spec get_for_task(String.t()) :: [map()]
  def get_for_task(task_id) do
    from(pc in PushConfigSchema, where: pc.task_id == ^task_id)
    |> Repo.all()
    |> Enum.map(&to_map/1)
  end

  @doc "Get a push config by ID."
  @spec get(String.t()) :: map() | nil
  def get(id) do
    case Repo.get(PushConfigSchema, id) do
      nil -> nil
      rec -> to_map(rec)
    end
  end

  @doc "Delete a push config by ID."
  @spec delete(String.t()) :: :ok
  def delete(id) do
    Repo.delete_all(from(pc in PushConfigSchema, where: pc.id == ^id))
    :ok
  end

  @doc "Delete all push configs for a task."
  @spec delete_for_task(String.t()) :: :ok
  def delete_for_task(task_id) do
    Repo.delete_all(from(pc in PushConfigSchema, where: pc.task_id == ^task_id))
    :ok
  end

  @doc "List all push configs."
  @spec list() :: [map()]
  def list do
    PushConfigSchema
    |> Repo.all()
    |> Enum.map(&to_map/1)
  end

  # -------------------------------------------------------------------
  # Private Helpers
  # -------------------------------------------------------------------

  defp build_config(task_id, params) do
    %{
      id: Utils.new_id(),
      task_id: task_id,
      url: Map.get(params, "url"),
      token: Map.get(params, "token"),
      hmac_secret: Map.get(params, "hmacSecret"),
      jwt_secret: Map.get(params, "jwtSecret"),
      jwt_issuer: Map.get(params, "jwtIssuer"),
      jwt_audience: Map.get(params, "jwtAudience"),
      jwt_kid: Map.get(params, "jwtKid"),
      authentication: Map.get(params, "authentication")
    }
  end

  defp to_map(%PushConfigSchema{} = rec) do
    %{
      "id" => rec.id,
      "taskId" => rec.task_id,
      "url" => rec.url,
      "token" => rec.token,
      "hmacSecret" => rec.hmac_secret,
      "jwtSecret" => rec.jwt_secret,
      "jwtIssuer" => rec.jwt_issuer,
      "jwtAudience" => rec.jwt_audience,
      "jwtKid" => rec.jwt_kid,
      "authentication" => rec.authentication
    }
  end
end
