defmodule Orchestrator.Infra.ClusterTest do
  @moduledoc """
  Tests for Infra.Cluster - cluster status and load balancing.
  """
  use ExUnit.Case, async: false

  alias Orchestrator.Infra.Cluster

  describe "status/0" do
    test "returns status map" do
      status = Cluster.status()

      assert is_map(status)
      assert is_atom(status.node)
      assert is_list(status.nodes)
      assert is_integer(status.node_count)
      assert status.node_count >= 1
      assert is_integer(status.local_workers)
    end

    test "includes current node in nodes list" do
      status = Cluster.status()
      assert node() in status.nodes
    end
  end

  describe "load_info/0" do
    test "returns list of node loads" do
      info = Cluster.load_info()

      assert is_list(info)
      assert length(info) >= 1

      # Check first entry
      [first | _] = info
      assert is_map(first)
      assert is_atom(first.node)
      assert first.workers == :unavailable or is_integer(first.workers)
    end
  end

  describe "clustered?/0" do
    test "returns boolean" do
      result = Cluster.clustered?()
      assert is_boolean(result)
    end

    test "returns false when no other nodes" do
      # In test mode, we typically run single node
      if Node.list() == [] do
        assert Cluster.clustered?() == false
      end
    end
  end

  describe "best_node_for/1" do
    test "returns a node" do
      result = Cluster.best_node_for("test-agent")
      assert is_atom(result)
    end

    test "returns current node when single node" do
      if Node.list() == [] do
        result = Cluster.best_node_for("test-agent")
        assert result == node()
      end
    end

    test "handles nonexistent agent" do
      result = Cluster.best_node_for("nonexistent-agent-#{:rand.uniform(100_000)}")
      assert is_atom(result)
    end
  end

  describe "node_alive?/1" do
    test "returns true for current node" do
      assert Cluster.node_alive?(node()) == true
    end

    test "returns false for unknown node" do
      assert Cluster.node_alive?(:unknown_node@nonexistent) == false
    end

    test "returns boolean for any node" do
      result = Cluster.node_alive?(:some_node@localhost)
      assert is_boolean(result)
    end
  end

  describe "module functions" do
    test "Infra.Cluster module is accessible" do
      assert Code.ensure_loaded?(Orchestrator.Infra.Cluster)
    end

    test "has status/0 function" do
      assert function_exported?(Orchestrator.Infra.Cluster, :status, 0)
    end

    test "has load_info/0 function" do
      assert function_exported?(Orchestrator.Infra.Cluster, :load_info, 0)
    end

    test "has best_node_for/1 function" do
      assert function_exported?(Orchestrator.Infra.Cluster, :best_node_for, 1)
    end
  end
end
