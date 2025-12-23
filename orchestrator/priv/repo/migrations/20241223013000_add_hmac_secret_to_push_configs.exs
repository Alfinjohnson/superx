defmodule Orchestrator.Repo.Migrations.AddHmacSecretToPushConfigs do
  use Ecto.Migration

  def change do
    alter table(:push_configs) do
      add :hmac_secret, :string
    end
  end
end
