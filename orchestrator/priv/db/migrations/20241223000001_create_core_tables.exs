defmodule Orchestrator.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    # Tasks table - stores A2A task payloads
    create table(:tasks, primary_key: false) do
      add :id, :string, primary_key: true
      add :payload, :jsonb, null: false

      timestamps()
    end

    create index(:tasks, [:inserted_at])

    # Agents table - stores agent configurations
    create table(:agents, primary_key: false) do
      add :id, :string, primary_key: true
      add :url, :string, null: false
      add :bearer, :string
      add :metadata, :jsonb, default: "{}"

      timestamps()
    end

    create index(:agents, [:url])

    # Push configs table - webhook configurations per task
    create table(:push_configs, primary_key: false) do
      add :id, :string, primary_key: true
      add :task_id, references(:tasks, type: :string, on_delete: :delete_all), null: false
      add :url, :string, null: false

      # Authentication options
      add :token, :string
      add :hmac_secret, :string
      add :jwt_secret, :string
      add :jwt_issuer, :string
      add :jwt_audience, :string
      add :jwt_kid, :string
      add :authentication, :jsonb

      timestamps()
    end

    create index(:push_configs, [:task_id])
  end
end
