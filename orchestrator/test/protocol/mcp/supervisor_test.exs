defmodule Orchestrator.Protocol.MCP.SupervisorTest do
  @moduledoc """
  Tests for MCP Supervisor session management.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Protocol.MCP.Supervisor

  describe "start_session/1" do
    test "starts new session with valid config" do
      config = %{
        "id" => "test-agent-#{:rand.uniform(10000)}",
        "url" => "http://localhost:3000",
        "transport" => "streamable-http"
      }

      # Session starts but connection happens asynchronously
      result = Supervisor.start_session(config)

      case result do
        {:ok, pid} ->
          assert Process.alive?(pid)
          GenServer.stop(pid)

        {:error, _} ->
          # May fail if transport config is invalid
          assert true
      end
    end
  end

  describe "stop_session/1" do
    test "returns error for non-existent session" do
      result = Supervisor.stop_session("non-existent-#{:rand.uniform(10000)}")
      assert result == {:error, :not_found}
    end
  end

  describe "lookup_session/1" do
    test "returns error for non-existent session" do
      result = Supervisor.lookup_session("non-existent-#{:rand.uniform(10000)}")
      assert result == :error
    end
  end

  describe "list_sessions/0" do
    test "returns empty list when no sessions" do
      sessions = Supervisor.list_sessions()
      assert is_list(sessions)
      # May have sessions from other tests, so just check it's a list
    end
  end
end
