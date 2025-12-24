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
  end
end
