defmodule Orchestrator.Protocol.MCP.Transport.STDIOTest do
  @moduledoc """
  Tests for MCP STDIO Transport.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Protocol.MCP.Transport.STDIO

  describe "module" do
    test "module exists and implements Transport behaviour" do
      assert Code.ensure_loaded?(STDIO)
      assert function_exported?(STDIO, :connect, 1)
      assert function_exported?(STDIO, :send_message, 2)
    end

    test "exports request/3" do
      assert function_exported?(STDIO, :request, 3)
    end

    test "exports start_streaming/2" do
      assert function_exported?(STDIO, :start_streaming, 2)
    end

    test "exports stop_streaming/1" do
      assert function_exported?(STDIO, :stop_streaming, 1)
    end

    test "exports close/1" do
      assert function_exported?(STDIO, :close, 1)
    end

    test "exports info/1" do
      assert function_exported?(STDIO, :info, 1)
    end
  end

  describe "struct" do
    test "has expected fields" do
      state = %STDIO{}

      assert Map.has_key?(state, :command)
      assert Map.has_key?(state, :args)
      assert Map.has_key?(state, :env)
      assert Map.has_key?(state, :port)
      assert Map.has_key?(state, :os_pid)
      assert Map.has_key?(state, :timeout)
      assert Map.has_key?(state, :buffer)
      assert Map.has_key?(state, :pending_requests)
      assert Map.has_key?(state, :receiver_pid)
    end

    test "default values are nil" do
      state = %STDIO{}

      assert state.command == nil
      assert state.args == nil
      assert state.port == nil
      assert state.os_pid == nil
    end
  end

  describe "close/1" do
    test "handles nil port gracefully" do
      state = %STDIO{port: nil, os_pid: nil}
      result = STDIO.close(state)
      assert result == :ok
    end
  end
end
