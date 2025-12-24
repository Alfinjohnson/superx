defmodule Orchestrator.Persistence do
  @moduledoc """
  Persistence configuration for SuperX.

  SuperX uses hybrid mode: OTP-managed in-memory task storage
  that works across cluster nodes via Horde.

  ## Features

  - No database required
  - OTP-managed in-memory state (replicated across nodes via Horde)
  - Data lost on restart
  - All APIs work: tasks.get, tasks.subscribe, message.send, etc.
  - Best for: Most deployments, dev/test, edge deployments
  """

  @doc """
  Returns the persistence mode. Always `:memory` (hybrid mode).
  """
  @spec mode() :: :memory
  def mode, do: :memory

  @doc """
  Returns true - always uses in-memory mode.
  """
  @spec memory?() :: true
  def memory?, do: true

  @doc """
  Returns the task storage adapter module.
  """
  @spec task_adapter() :: module()
  def task_adapter, do: Orchestrator.Task.Store.Distributed

  @doc """
  Returns the agent storage adapter module.
  """
  @spec agent_adapter() :: module()
  def agent_adapter, do: Orchestrator.Agent.Store.Memory

  @doc """
  Returns the push config storage adapter module.
  """
  @spec push_config_adapter() :: module()
  def push_config_adapter, do: Orchestrator.Task.PushConfig.Memory
end
