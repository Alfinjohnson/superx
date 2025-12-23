defmodule Orchestrator.Persistence do
  @moduledoc """
  Persistence configuration for SuperX.

  SuperX supports two persistence modes:

  ## PostgreSQL Mode (Scalable)

      config :orchestrator, persistence: :postgres

  - Data persisted to PostgreSQL
  - Horizontally scalable (shared database)
  - Full task history and audit trail
  - Best for: Production, multi-node deployments

  ## Memory Mode (Stateless)

      config :orchestrator, persistence: :memory

  - No database required
  - All data stored in ETS tables (per-node)
  - Data lost on restart
  - Best for: Simple gateway, dev/test, edge deployments

  ## Default

  Defaults to `:postgres` for production use cases.
  """

  @doc """
  Returns the configured persistence mode.

  Returns `:memory` or `:postgres`.

  Checks in order:
  1. SUPERX_PERSISTENCE environment variable (runtime override)
  2. Application config `:orchestrator, :persistence`
  3. Default: `:postgres`
  """
  @spec mode() :: :memory | :postgres
  def mode do
    case System.get_env("SUPERX_PERSISTENCE") do
      nil ->
        Application.get_env(:orchestrator, :persistence, :postgres)

      value ->
        # Trim whitespace to handle Windows cmd.exe quirks
        case String.trim(value) do
          "memory" -> :memory
          "postgres" -> :postgres
          _ -> Application.get_env(:orchestrator, :persistence, :postgres)
        end
    end
  end

  @doc """
  Returns true if using in-memory (stateless) mode.
  """
  @spec memory?() :: boolean()
  def memory?, do: mode() == :memory

  @doc """
  Returns true if using PostgreSQL (stateful) mode.
  """
  @spec postgres?() :: boolean()
  def postgres?, do: mode() == :postgres

  @doc """
  Returns the appropriate adapter module for task storage.
  """
  @spec task_adapter() :: module()
  def task_adapter do
    case mode() do
      :memory -> Orchestrator.Task.Store.Memory
      :postgres -> Orchestrator.Task.Store.Postgres
    end
  end

  @doc """
  Returns the appropriate adapter module for agent storage.
  """
  @spec agent_adapter() :: module()
  def agent_adapter do
    case mode() do
      :memory -> Orchestrator.Agent.Store.Memory
      :postgres -> Orchestrator.Agent.Store.Postgres
    end
  end

  @doc """
  Returns the appropriate adapter module for push config storage.
  """
  @spec push_config_adapter() :: module()
  def push_config_adapter do
    case mode() do
      :memory -> Orchestrator.Task.PushConfig.Memory
      :postgres -> Orchestrator.Task.PushConfig.Postgres
    end
  end
end
