defmodule Orchestrator.Repo do
  @moduledoc """
  PostgreSQL repository for durable, strongly consistent storage.

  This is only used when persistence mode is set to :postgres or :postgres_cached.
  By default, the system runs in :memory mode without any database.

  ## Configuration

  Set these in config/runtime.exs or via environment variables:

      config :orchestrator, Orchestrator.Repo,
        url: System.get_env("DATABASE_URL"),
        pool_size: String.to_integer(System.get_env("DB_POOL_SIZE") || "10")

  Or individual components:
  - DATABASE_HOST
  - DATABASE_PORT
  - DATABASE_USER
  - DATABASE_PASSWORD
  - DATABASE_NAME
  """

  use Ecto.Repo,
    otp_app: :orchestrator,
    adapter: Ecto.Adapters.Postgres
end
