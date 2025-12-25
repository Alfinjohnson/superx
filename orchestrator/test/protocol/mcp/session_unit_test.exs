defmodule Orchestrator.Protocol.MCP.SessionUnitTest do
  @moduledoc """
  Unit tests for MCP.Session module - testing individual functions.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Protocol.MCP.Session

  describe "module structure" do
    test "Session module is loaded" do
      assert Code.ensure_loaded?(Session)
    end

    test "has start_link/2 function" do
      assert function_exported?(Session, :start_link, 2)
    end

    test "has call_tool/4 function" do
      assert function_exported?(Session, :call_tool, 4)
    end

    test "has list_tools/2 function" do
      assert function_exported?(Session, :list_tools, 2)
    end

    test "has list_resources/2 function" do
      assert function_exported?(Session, :list_resources, 2)
    end

    test "has list_prompts/2 function" do
      assert function_exported?(Session, :list_prompts, 2)
    end

    test "has read_resource/3 function" do
      assert function_exported?(Session, :read_resource, 3)
    end

    test "has get_prompt/4 function" do
      assert function_exported?(Session, :get_prompt, 4)
    end

    test "has request/4 function" do
      assert function_exported?(Session, :request, 4)
    end

    test "has info/1 function" do
      assert function_exported?(Session, :info, 1)
    end

    test "has get_agent_card/1 function" do
      assert function_exported?(Session, :get_agent_card, 1)
    end

    test "has close/1 function" do
      assert function_exported?(Session, :close, 1)
    end
  end

  describe "session struct" do
    test "struct has expected fields" do
      session = %Session{}

      assert Map.has_key?(session, :server_id)
      assert Map.has_key?(session, :server_config)
      assert Map.has_key?(session, :transport_module)
      assert Map.has_key?(session, :transport_state)
      assert Map.has_key?(session, :session_state)
      assert Map.has_key?(session, :server_info)
      assert Map.has_key?(session, :capabilities)
      assert Map.has_key?(session, :tools)
      assert Map.has_key?(session, :resources)
      assert Map.has_key?(session, :prompts)
      assert Map.has_key?(session, :pending_requests)
    end

    test "initial state values are nil" do
      session = %Session{}

      assert session.server_id == nil
      assert session.server_info == nil
      assert session.capabilities == nil
      assert session.tools == nil
    end
  end
end
