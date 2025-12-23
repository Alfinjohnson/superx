defmodule Orchestrator.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :string, primary_key: true
      add :url, :string, null: false
      add :bearer, :string
      add :metadata, :map

      timestamps()
    end
  end
end
