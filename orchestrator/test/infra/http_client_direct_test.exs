defmodule Orchestrator.Infra.HttpClientDirectTest do
  @moduledoc """
  Direct tests for Orchestrator.Infra.HttpClient module.
  Tests the actual module functions without HTTP mocking for coverage.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Infra.HttpClient

  describe "module structure" do
    test "module is loaded" do
      assert Code.ensure_loaded?(HttpClient)
    end

    test "exports post_json/3" do
      assert function_exported?(HttpClient, :post_json, 3)
    end

    test "exports post_json/2" do
      assert function_exported?(HttpClient, :post_json, 2)
    end

    test "exports get_json/2" do
      assert function_exported?(HttpClient, :get_json, 2)
    end

    test "exports get_json/1" do
      assert function_exported?(HttpClient, :get_json, 1)
    end

    test "exports fetch_agent_card/2" do
      assert function_exported?(HttpClient, :fetch_agent_card, 2)
    end

    test "exports post_raw/3" do
      assert function_exported?(HttpClient, :post_raw, 3)
    end
  end

  describe "post_json/3 error handling" do
    test "raises for invalid URL (no scheme)" do
      # Req/Finch raises ArgumentError for malformed URLs
      assert_raise ArgumentError, fn ->
        HttpClient.post_json("not-a-url", %{}, timeout: 100)
      end
    end

    test "returns timeout error for unreachable host" do
      # Use a non-routable IP to force timeout
      result = HttpClient.post_json("http://10.255.255.1/rpc", %{}, timeout: 100)
      assert {:error, _reason} = result
    end
  end

  describe "get_json/2 error handling" do
    test "raises for invalid URL (no scheme)" do
      assert_raise ArgumentError, fn ->
        HttpClient.get_json("not-a-url", timeout: 100)
      end
    end

    test "returns timeout error for unreachable host" do
      result = HttpClient.get_json("http://10.255.255.1/data", timeout: 100)
      assert {:error, _reason} = result
    end
  end

  describe "fetch_agent_card/2 error handling" do
    test "raises for invalid URL (no scheme)" do
      assert_raise ArgumentError, fn ->
        HttpClient.fetch_agent_card("not-a-url", timeout: 100)
      end
    end
  end

  describe "post_raw/3" do
    test "raises for invalid URL (no scheme)" do
      assert_raise ArgumentError, fn ->
        HttpClient.post_raw("not-a-url", %{})
      end
    end
  end
end
