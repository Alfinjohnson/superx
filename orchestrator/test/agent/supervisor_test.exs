defmodule Orchestrator.Agent.SupervisorTest do
  @moduledoc """
  Tests for Agent.Supervisor - distributed worker supervision.
  """
  use ExUnit.Case, async: false

  alias Orchestrator.Agent.Supervisor, as: AgentSupervisor
  alias Orchestrator.Agent.Store, as: AgentStore

  setup do
    agent_id = "supervisor-test-agent-#{:rand.uniform(100_000)}"

    agent = %{
      "id" => agent_id,
      "url" => "http://localhost:9999",
      "protocol" => "a2a"
    }

    on_exit(fn ->
      # Terminate worker if exists
      AgentSupervisor.terminate_worker(agent_id)
      AgentStore.delete(agent_id)
    end)

    {:ok, agent_id: agent_id, agent: agent}
  end

  describe "start_worker/1" do
    test "starts a worker for an agent", %{agent: agent} do
      result = AgentSupervisor.start_worker(agent)

      assert {:ok, pid} = result
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "returns existing pid if worker already started", %{agent: agent} do
      {:ok, pid1} = AgentSupervisor.start_worker(agent)
      {:ok, pid2} = AgentSupervisor.start_worker(agent)

      assert pid1 == pid2
    end

    test "starts workers for different agents" do
      agent1 = %{"id" => "agent-1-#{:rand.uniform(100_000)}", "url" => "http://localhost:9001"}
      agent2 = %{"id" => "agent-2-#{:rand.uniform(100_000)}", "url" => "http://localhost:9002"}

      {:ok, pid1} = AgentSupervisor.start_worker(agent1)
      {:ok, pid2} = AgentSupervisor.start_worker(agent2)

      assert pid1 != pid2

      # Cleanup
      AgentSupervisor.terminate_worker(agent1["id"])
      AgentSupervisor.terminate_worker(agent2["id"])
    end
  end

  describe "terminate_worker/1" do
    test "terminates an existing worker", %{agent: agent, agent_id: agent_id} do
      {:ok, pid} = AgentSupervisor.start_worker(agent)
      assert Process.alive?(pid)

      result = AgentSupervisor.terminate_worker(agent_id)

      assert result == :ok
      # Give it time to terminate
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "returns error for nonexistent worker" do
      result = AgentSupervisor.terminate_worker("nonexistent-#{:rand.uniform(100_000)}")

      assert result == {:error, :not_found}
    end
  end

  describe "local_worker_count/0" do
    test "returns count of local workers" do
      initial_count = AgentSupervisor.local_worker_count()
      assert is_integer(initial_count)
      assert initial_count >= 0
    end

    test "increases when worker started", %{agent: agent} do
      initial_count = AgentSupervisor.local_worker_count()

      {:ok, _pid} = AgentSupervisor.start_worker(agent)

      new_count = AgentSupervisor.local_worker_count()
      assert new_count > initial_count
    end
  end

  describe "list_workers/0" do
    test "returns list of worker pids" do
      workers = AgentSupervisor.list_workers()

      assert is_list(workers)
      Enum.each(workers, fn pid ->
        assert is_pid(pid)
      end)
    end

    test "includes newly started worker", %{agent: agent, agent_id: agent_id} do
      {:ok, pid} = AgentSupervisor.start_worker(agent)

      workers = AgentSupervisor.list_workers()
      assert pid in workers

      AgentSupervisor.terminate_worker(agent_id)
    end
  end
end

# Also test backward compatibility alias
defmodule Orchestrator.AgentSupervisorCompatTest do
  @moduledoc """
  Tests for backward-compatible AgentSupervisor alias.
  """
  use ExUnit.Case, async: false

  alias Orchestrator.AgentSupervisor

  describe "backward compatibility" do
    test "local_worker_count/0 works" do
      count = AgentSupervisor.local_worker_count()
      assert is_integer(count)
    end
  end
end
