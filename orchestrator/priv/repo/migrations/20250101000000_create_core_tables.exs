defmodule Orchestrator.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    # Tasks table - stores all task state
    create table(:tasks, primary_key: false) do
      add :id, :string, primary_key: true
      add :status, :map, null: false
      add :message, :map
      add :context_id, :string
      add :agent_id, :string
      add :result, :map
      add :artifacts, {:array, :map}, default: []
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tasks, [:agent_id])
    create index(:tasks, [:context_id])
    create index(:tasks, ["(status->>'state')"], name: :tasks_status_state_index)
    create index(:tasks, [:inserted_at])

    # Agents table - stores agent configurations
    create table(:agents, primary_key: false) do
      add :id, :string, primary_key: true
      add :url, :string, null: false
      add :bearer, :string
      add :protocol, :string, default: "a2a"
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, [:url])

    # Push notification configs
    create table(:push_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :string, on_delete: :delete_all)
      add :url, :string, null: false
      add :token, :string
      add :hmac_secret, :string
      add :jwt_secret, :string
      add :jwt_issuer, :string
      add :jwt_audience, :string
      add :jwt_kid, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:push_configs, [:task_id])
  end
end
