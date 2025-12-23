defmodule Orchestrator.Schema.Task do
  @moduledoc """
  Ecto schema for persisted A2A tasks.

  ## Fields

  - `id` - Task ID (from A2A protocol)
  - `payload` - Full task JSON payload

  ## Payload Structure

  The payload contains the complete A2A task including:

      %{
        "id" => "task-123",
        "status" => %{"state" => "completed"},
        "artifacts" => [...],
        "history" => [...],
        "metadata" => %{...}
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: String.t(),
          payload: map(),
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "tasks" do
    field :payload, :map
    timestamps()
  end

  @required_fields ~w(id payload)a

  @doc """
  Create a changeset for task creation/update.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
  end

  @doc """
  Convert a Task schema to its payload map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{payload: payload}), do: payload
end

# Backward compatibility alias
defmodule Orchestrator.TaskRecord do
  @moduledoc false
  defdelegate changeset(struct, attrs), to: Orchestrator.Schema.Task
  defdelegate to_map(task), to: Orchestrator.Schema.Task
end
