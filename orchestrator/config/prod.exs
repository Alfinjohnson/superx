import Config

# Production specific configuration
config :logger, level: :info

# Production PostgreSQL - use DATABASE_URL or individual env vars
# Supports connection pooling and SSL
config :orchestrator, Orchestrator.Repo,
  url: System.get_env("DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "20")),
  queue_target: 50,
  queue_interval: 1000,
  ssl: System.get_env("DB_SSL", "false") == "true",
  ssl_opts: [verify: :verify_none]

# For stateless mode in production, set:
# config :orchestrator, persistence: :memory
