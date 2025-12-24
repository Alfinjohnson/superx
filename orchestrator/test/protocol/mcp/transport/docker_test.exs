defmodule Orchestrator.Protocol.MCP.Transport.DockerTest do
  @moduledoc """
  Tests for MCP Docker Transport helper.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Protocol.MCP.Transport.Docker

  describe "module" do
    test "module exists with helper functions" do
      assert Code.ensure_loaded?(Docker)
      assert function_exported?(Docker, :oci_package?, 1)
      assert function_exported?(Docker, :prepare_transport, 1)
    end
  end
end
