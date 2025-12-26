defmodule Orchestrator.Persistence do
  @moduledoc """
  Persistence configuration for SuperX.

  SuperX uses a hybrid PostgreSQL + ETS caching approach:
  - **PostgreSQL**: Provides ACID guarantees, durability, and crash recovery
  - **ETS Cache**: Provides sub-millisecond read performance
  - **Write-through caching**: Writes go to PostgreSQL first, then cache

  ## Performance Characteristics
  - Reads: ~0.5ms (ETS cache hit)
  - Writes: ~5ms (PostgreSQL + ETS update)
  - Cache miss reads: ~5ms (PostgreSQL + cache populate)

  ## Features
  - ACID transactions
  - No data loss on crash
  - Cluster-friendly (each node has its own cache)
  - Test-friendly (Ecto sandbox for isolation)

  ## Database Setup

  Set the DATABASE_URL environment variable:

      export DATABASE_URL="postgresql://user:pass@localhost/orchestrator_dev"
      mix ecto.setup
  """

  @doc """
  Returns the task storage adapter module.
  """
  @spec task_adapter() :: module()
  def task_adapter, do: Orchestrator.Task.Store.CachedPostgres

  @doc """
  Returns the agent storage adapter module.
  """
  @spec agent_adapter() :: module()
  def agent_adapter, do: Orchestrator.Agent.Store.CachedPostgres

  @doc """
  Returns the push config storage adapter module.
  """
  @spec push_config_adapter() :: module()
  def push_config_adapter, do: Orchestrator.Task.PushConfig.CachedPostgres
end
