import Config

# Configure PostgreSQL repository
# Set DATABASE_URL for simple configuration, or individual variables
if config_env() != :test do
  config :orchestrator, Orchestrator.Repo,
    url: System.get_env("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("DB_POOL_SIZE") || "10"),
    queue_target: 50,
    queue_interval: 1_000
end

# Test environment configuration
if config_env() == :test do
  config :orchestrator, Orchestrator.Repo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    port: 5433,
    database: "orchestrator_test#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10
end
