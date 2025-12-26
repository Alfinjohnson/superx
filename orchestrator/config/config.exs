import Config

# Default configuration for all environments
# PostgreSQL with ETS caching for all environments

# Ecto repositories
config :orchestrator, ecto_repos: [Orchestrator.Repo]

# Import environment-specific configuration
import_config "#{config_env()}.exs"
