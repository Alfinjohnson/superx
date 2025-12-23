defmodule Orchestrator.Repo.Migrations.CreateTasksAndPushConfigs do
  use Ecto.Migration

  def change do
    create table(:tasks, primary_key: false) do
      add :id, :string, primary_key: true
      add :payload, :map, null: false

      timestamps()
    end

    create table(:push_configs, primary_key: false) do
      add :id, :string, primary_key: true
      add :task_id, references(:tasks, type: :string, on_delete: :delete_all), null: false
      add :url, :string, null: false
      add :token, :string
      add :authentication, :map

      timestamps()
    end

    create index(:push_configs, [:task_id])
  end
end
