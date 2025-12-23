defmodule Orchestrator.Protocol.Methods do
  @moduledoc """
  Canonical method definitions for A2A protocol operations.

  This module defines the internal canonical method names used throughout the orchestrator.
  Protocol adapters translate between wire format and these canonical names.

  ## Canonical Methods

  | Canonical Name | Description |
  |----------------|-------------|
  | `:send_message` | Send a message to initiate/continue a task |
  | `:stream_message` | Send message with streaming response |
  | `:get_task` | Get current task state |
  | `:list_tasks` | List tasks with filtering |
  | `:cancel_task` | Cancel an ongoing task |
  | `:subscribe_task` | Subscribe to task updates |
  | `:set_push_config` | Set push notification config |
  | `:get_push_config` | Get push notification config |
  | `:list_push_configs` | List push notification configs |
  | `:delete_push_config` | Delete push notification config |
  | `:get_agent_card` | Get extended agent card |

  ## Adding New Methods

  When a new A2A protocol version adds methods:
  1. Add the canonical name here
  2. Update the protocol adapter to map wire <-> canonical
  3. Implement handling in router if needed
  """

  @type canonical_method ::
          :send_message
          | :stream_message
          | :get_task
          | :list_tasks
          | :cancel_task
          | :subscribe_task
          | :set_push_config
          | :get_push_config
          | :list_push_configs
          | :delete_push_config
          | :get_agent_card
          | :unknown

  @doc "All supported canonical method names."
  def all do
    [
      :send_message,
      :stream_message,
      :get_task,
      :list_tasks,
      :cancel_task,
      :subscribe_task,
      :set_push_config,
      :get_push_config,
      :list_push_configs,
      :delete_push_config,
      :get_agent_card
    ]
  end

  @doc "Check if a canonical method requires streaming response."
  def streaming?(:stream_message), do: true
  def streaming?(:subscribe_task), do: true
  def streaming?(_), do: false

  @doc "Check if method is a task management operation."
  def task_method?(:get_task), do: true
  def task_method?(:list_tasks), do: true
  def task_method?(:cancel_task), do: true
  def task_method?(:subscribe_task), do: true
  def task_method?(_), do: false

  @doc "Check if method is a push notification operation."
  def push_method?(:set_push_config), do: true
  def push_method?(:get_push_config), do: true
  def push_method?(:list_push_configs), do: true
  def push_method?(:delete_push_config), do: true
  def push_method?(_), do: false
end
