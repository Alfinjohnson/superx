defmodule Orchestrator.Protocol.MethodsTest do
  @moduledoc """
  Tests for Protocol.Methods - canonical method definitions.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Protocol.Methods

  describe "all/0" do
    test "returns A2A methods" do
      all_methods = Methods.all()

      assert is_list(all_methods)
      assert length(all_methods) > 10

      # Contains A2A methods
      assert :send_message in all_methods
      assert :get_task in all_methods
    end
  end

  describe "a2a_methods/0" do
    test "returns all A2A protocol methods" do
      methods = Methods.a2a_methods()

      assert :send_message in methods
      assert :stream_message in methods
      assert :get_task in methods
      assert :list_tasks in methods
      assert :cancel_task in methods
      assert :subscribe_task in methods
      assert :set_push_config in methods
      assert :get_push_config in methods
      assert :list_push_configs in methods
      assert :delete_push_config in methods
      assert :get_agent_card in methods
    end
  end

  describe "streaming?/1" do
    test "returns true for streaming methods" do
      assert Methods.streaming?(:stream_message) == true
      assert Methods.streaming?(:subscribe_task) == true
    end

    test "returns false for non-streaming methods" do
      assert Methods.streaming?(:send_message) == false
      assert Methods.streaming?(:get_task) == false
      assert Methods.streaming?(:list_tools) == false
    end
  end

  describe "task_method?/1" do
    test "returns true for task management methods" do
      assert Methods.task_method?(:get_task) == true
      assert Methods.task_method?(:list_tasks) == true
      assert Methods.task_method?(:cancel_task) == true
      assert Methods.task_method?(:subscribe_task) == true
    end

    test "returns false for non-task methods" do
      assert Methods.task_method?(:send_message) == false
      assert Methods.task_method?(:list_tools) == false
    end
  end

  describe "push_method?/1" do
    test "returns true for push notification methods" do
      assert Methods.push_method?(:set_push_config) == true
      assert Methods.push_method?(:get_push_config) == true
      assert Methods.push_method?(:list_push_configs) == true
      assert Methods.push_method?(:delete_push_config) == true
    end

    test "returns false for non-push methods" do
      assert Methods.push_method?(:send_message) == false
      assert Methods.push_method?(:get_task) == false
    end
  end

  describe "mcp_tool_method?/1" do
    test "returns true for MCP tool methods" do
      assert Methods.mcp_tool_method?(:list_tools) == true
      assert Methods.mcp_tool_method?(:call_tool) == true
      assert Methods.mcp_tool_method?(:tools_changed) == true
    end

    test "returns false for non-tool methods" do
      assert Methods.mcp_tool_method?(:initialize) == false
      assert Methods.mcp_tool_method?(:list_resources) == false
    end
  end

  describe "mcp_resource_method?/1" do
    test "returns true for MCP resource methods" do
      assert Methods.mcp_resource_method?(:list_resources) == true
      assert Methods.mcp_resource_method?(:list_resource_templates) == true
      assert Methods.mcp_resource_method?(:read_resource) == true
      assert Methods.mcp_resource_method?(:subscribe_resource) == true
      assert Methods.mcp_resource_method?(:unsubscribe_resource) == true
      assert Methods.mcp_resource_method?(:resources_changed) == true
      assert Methods.mcp_resource_method?(:resource_updated) == true
    end

    test "returns false for non-resource methods" do
      assert Methods.mcp_resource_method?(:list_tools) == false
      assert Methods.mcp_resource_method?(:initialize) == false
    end
  end

  describe "mcp_prompt_method?/1" do
    test "returns true for MCP prompt methods" do
      assert Methods.mcp_prompt_method?(:list_prompts) == true
      assert Methods.mcp_prompt_method?(:get_prompt) == true
      assert Methods.mcp_prompt_method?(:prompts_changed) == true
    end

    test "returns false for non-prompt methods" do
      assert Methods.mcp_prompt_method?(:list_tools) == false
      assert Methods.mcp_prompt_method?(:initialize) == false
    end
  end

  describe "mcp_notification?/1" do
    test "returns true for MCP notification methods" do
      assert Methods.mcp_notification?(:initialized) == true
      assert Methods.mcp_notification?(:tools_changed) == true
      assert Methods.mcp_notification?(:resources_changed) == true
      assert Methods.mcp_notification?(:resource_updated) == true
      assert Methods.mcp_notification?(:prompts_changed) == true
      assert Methods.mcp_notification?(:roots_changed) == true
      assert Methods.mcp_notification?(:log_message) == true
      assert Methods.mcp_notification?(:progress) == true
      assert Methods.mcp_notification?(:cancelled) == true
    end

    test "returns false for non-notification methods" do
      assert Methods.mcp_notification?(:initialize) == false
      assert Methods.mcp_notification?(:list_tools) == false
      assert Methods.mcp_notification?(:call_tool) == false
    end
  end

  describe "mcp_server_request?/1" do
    test "returns true for server-to-client request methods" do
      assert Methods.mcp_server_request?(:create_message) == true
      assert Methods.mcp_server_request?(:create_elicitation) == true
      assert Methods.mcp_server_request?(:list_roots) == true
    end

    test "returns false for client-to-server methods" do
      assert Methods.mcp_server_request?(:initialize) == false
      assert Methods.mcp_server_request?(:list_tools) == false
      assert Methods.mcp_server_request?(:call_tool) == false
    end
  end
end
