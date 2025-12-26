defmodule Orchestrator.Schema.Task do
  @moduledoc """
  Ecto schema for tasks stored in PostgreSQL.

  Maps to the `tasks` table created in migrations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "tasks" do
    field(:status, :map)
    field(:message, :map)
    field(:context_id, :string)
    field(:agent_id, :string)
    field(:result, :map)
    field(:artifacts, {:array, :map}, default: [])
    field(:metadata, :map, default: %{})

    has_many(:push_configs, Orchestrator.Schema.PushConfig, foreign_key: :task_id)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating or updating a task.

  ## Required fields
  - id
  - status

  ## Optional fields
  - message
  - context_id
  - agent_id
  - result
  - artifacts
  - metadata
  """
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :id,
      :status,
      :message,
      :context_id,
      :agent_id,
      :result,
      :artifacts,
      :metadata
    ])
    |> validate_required([:id, :status])
    |> unique_constraint(:id, name: :tasks_pkey)
    |> validate_status()
  end

  defp validate_status(changeset) do
    case get_field(changeset, :status) do
      %{"state" => state}
      when state in ["submitted", "working", "completed", "failed", "canceled"] ->
        changeset

      %{"state" => _} ->
        add_error(changeset, :status, "invalid state")

      _ ->
        add_error(changeset, :status, "must be a map with 'state' key")
    end
  end

  @doc """
  Convert Ecto schema to A2A protocol map format.
  """
  def to_map(%__MODULE__{} = task) do
    %{
      "id" => task.id,
      "status" => task.status,
      "message" => task.message,
      "contextId" => task.context_id,
      "agentId" => task.agent_id,
      "result" => task.result,
      "artifacts" => task.artifacts || [],
      "metadata" => task.metadata || %{}
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Convert A2A protocol map to Ecto changeset attrs.
  """
  def from_map(task_map) when is_map(task_map) do
    %{
      id: task_map["id"],
      status: task_map["status"],
      message: task_map["message"],
      context_id: task_map["contextId"],
      agent_id: task_map["agentId"],
      result: task_map["result"],
      artifacts: task_map["artifacts"] || [],
      metadata: task_map["metadata"] || %{}
    }
  end
end
