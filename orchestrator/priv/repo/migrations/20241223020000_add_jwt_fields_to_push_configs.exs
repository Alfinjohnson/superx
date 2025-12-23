defmodule Orchestrator.Repo.Migrations.AddJwtFieldsToPushConfigs do
  use Ecto.Migration

  def change do
    alter table(:push_configs) do
      add :jwt_secret, :string
      add :jwt_issuer, :string
      add :jwt_audience, :string
      add :jwt_kid, :string
    end
  end
end
