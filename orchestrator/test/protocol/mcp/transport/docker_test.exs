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

  describe "oci_package?/1" do
    test "returns true for OCI package with string keys" do
      config = %{"package" => %{"registryType" => "oci", "name" => "image:tag"}}
      assert Docker.oci_package?(config) == true
    end

    test "returns true for OCI package with atom keys" do
      config = %{package: %{registryType: "oci", name: "image:tag"}}
      assert Docker.oci_package?(config) == true
    end

    test "returns false for non-OCI package" do
      config = %{"package" => %{"registryType" => "npm", "name" => "@mcp/server"}}
      assert Docker.oci_package?(config) == false
    end

    test "returns false for missing package" do
      config = %{"command" => "node", "args" => ["server.js"]}
      assert Docker.oci_package?(config) == false
    end

    test "returns false for empty map" do
      assert Docker.oci_package?(%{}) == false
    end
  end

  describe "ensure_docker_available/0" do
    test "returns ok or docker_not_found based on system" do
      result = Docker.ensure_docker_available()
      assert result in [:ok, {:error, :docker_not_found}]
    end
  end
end
