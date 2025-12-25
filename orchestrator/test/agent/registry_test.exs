defmodule Orchestrator.Agent.RegistryTest do
  @moduledoc """
  Tests for Agent.Registry - distributed process registry.
  """
  use ExUnit.Case, async: false

  alias Orchestrator.Agent.Registry

  describe "lookup_worker/1" do
    test "returns :error when worker not found" do
      result = Registry.lookup_worker("nonexistent-agent-#{:rand.uniform(10000)}")

      assert result == :error
    end
  end

  describe "list_agent_ids/0" do
    test "returns list of agent IDs" do
      result = Registry.list_agent_ids()

      assert is_list(result)
    end
  end
end

defmodule Orchestrator.AgentRegistry.DistributedTest do
  @moduledoc """
  Tests for backward-compatible AgentRegistry.Distributed module.
  """
  use ExUnit.Case, async: false

  alias Orchestrator.AgentRegistry.Distributed

  describe "lookup/1" do
    test "returns empty list for nonexistent key" do
      result = Distributed.lookup({:agent_worker, "nonexistent-#{:rand.uniform(10000)}"})

      assert result == []
    end
  end
end
