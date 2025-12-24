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

  # A2A methods
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
          # MCP lifecycle methods
          | :initialize
          | :initialized
          | :ping
          | :shutdown
          # MCP tool methods
          | :list_tools
          | :call_tool
          | :tools_changed
          # MCP resource methods
          | :list_resources
          | :list_resource_templates
          | :read_resource
          | :subscribe_resource
          | :unsubscribe_resource
          | :resources_changed
          | :resource_updated
          # MCP prompt methods
          | :list_prompts
          | :get_prompt
          | :prompts_changed
          # MCP sampling/elicitation (bidirectional)
          | :create_message
          | :create_elicitation
          # MCP roots
          | :list_roots
          | :roots_changed
          # MCP logging
          | :set_log_level
          | :log_message
          # MCP progress
          | :progress
          | :cancelled
          | :unknown

  @doc "All supported canonical method names."
  def all do
    a2a_methods() ++ mcp_methods()
  end

  @doc "A2A protocol methods."
  def a2a_methods do
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

  @doc "MCP protocol methods."
  def mcp_methods do
    [
      # Lifecycle
      :initialize,
      :initialized,
      :ping,
      :shutdown,
      # Tools
      :list_tools,
      :call_tool,
      :tools_changed,
      # Resources
      :list_resources,
      :list_resource_templates,
      :read_resource,
      :subscribe_resource,
      :unsubscribe_resource,
      :resources_changed,
      :resource_updated,
      # Prompts
      :list_prompts,
      :get_prompt,
      :prompts_changed,
      # Sampling/Elicitation
      :create_message,
      :create_elicitation,
      # Roots
      :list_roots,
      :roots_changed,
      # Logging
      :set_log_level,
      :log_message,
      # Progress
      :progress,
      :cancelled
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

  @doc "Check if method is an MCP tool operation."
  def mcp_tool_method?(:list_tools), do: true
  def mcp_tool_method?(:call_tool), do: true
  def mcp_tool_method?(:tools_changed), do: true
  def mcp_tool_method?(_), do: false

  @doc "Check if method is an MCP resource operation."
  def mcp_resource_method?(:list_resources), do: true
  def mcp_resource_method?(:list_resource_templates), do: true
  def mcp_resource_method?(:read_resource), do: true
  def mcp_resource_method?(:subscribe_resource), do: true
  def mcp_resource_method?(:unsubscribe_resource), do: true
  def mcp_resource_method?(:resources_changed), do: true
  def mcp_resource_method?(:resource_updated), do: true
  def mcp_resource_method?(_), do: false

  @doc "Check if method is an MCP prompt operation."
  def mcp_prompt_method?(:list_prompts), do: true
  def mcp_prompt_method?(:get_prompt), do: true
  def mcp_prompt_method?(:prompts_changed), do: true
  def mcp_prompt_method?(_), do: false

  @doc "Check if method is an MCP notification (no response expected)."
  def mcp_notification?(:initialized), do: true
  def mcp_notification?(:tools_changed), do: true
  def mcp_notification?(:resources_changed), do: true
  def mcp_notification?(:resource_updated), do: true
  def mcp_notification?(:prompts_changed), do: true
  def mcp_notification?(:roots_changed), do: true
  def mcp_notification?(:log_message), do: true
  def mcp_notification?(:progress), do: true
  def mcp_notification?(:cancelled), do: true
  def mcp_notification?(_), do: false

  @doc "Check if method is an MCP server-to-client request (bidirectional)."
  def mcp_server_request?(:create_message), do: true
  def mcp_server_request?(:create_elicitation), do: true
  def mcp_server_request?(:list_roots), do: true
  def mcp_server_request?(_), do: false
end
