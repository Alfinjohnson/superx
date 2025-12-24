defmodule Orchestrator.Protocol.A2A.Template do
  @moduledoc """
  Template for implementing new A2A protocol versions.

  Copy this file and modify for each new A2A version:
  1. Rename module to `Orchestrator.Protocol.A2A.V0X0` (e.g., V040 for 0.4.0)
  2. Update @protocol_version
  3. Update @wire_to_canonical with new/changed method names
  4. Update encode/decode if wire format changes
  5. Update agent card handling if structure changes
  6. Add to Protocol.adapter_for/2

  ## Version Differences to Watch For

  - Method naming conventions (PascalCase vs snake_case vs slash)
  - Request/response field names
  - Agent card structure and required fields
  - Streaming format changes
  - New capabilities or features
  """

  # Uncomment and implement when needed:
  #
  # @behaviour Orchestrator.Protocol.Behaviour
  #
  # alias Orchestrator.Protocol.Envelope
  #
  # @protocol_name "a2a"
  # @protocol_version "X.Y.Z"  # Update this
  # @well_known_path "/.well-known/agent-card.json"
  #
  # # --- Method Mapping ---
  # # Update if method names change in new version
  #
  # @wire_to_canonical %{
  #   "SendMessage" => :send_message,
  #   "SendStreamingMessage" => :stream_message,
  #   "GetTask" => :get_task,
  #   "ListTasks" => :list_tasks,
  #   "CancelTask" => :cancel_task,
  #   "SubscribeToTask" => :subscribe_task,
  #   "SetTaskPushNotificationConfig" => :set_push_config,
  #   "GetTaskPushNotificationConfig" => :get_push_config,
  #   "ListTaskPushNotificationConfig" => :list_push_configs,
  #   "DeleteTaskPushNotificationConfig" => :delete_push_config,
  #   "GetExtendedAgentCard" => :get_agent_card
  #   # Add new methods here
  # }
  #
  # @canonical_to_wire Map.new(@wire_to_canonical, fn {k, v} -> {v, k} end)
  #
  # def protocol_name, do: @protocol_name
  # def protocol_version, do: @protocol_version
  #
  # @impl true
  # def normalize_method(wire_method), do: Map.get(@wire_to_canonical, wire_method, :unknown)
  #
  # @impl true
  # def wire_method(canonical), do: Map.get(@canonical_to_wire, canonical, to_string(canonical))
  #
  # # ... implement remaining callbacks from Orchestrator.Protocol.A2A.Adapter
end

# Backward compatibility alias
defmodule Orchestrator.Protocol.A2A_Template do
  @moduledoc false
  # This module serves as a template - no delegates needed
end
