defmodule Orchestrator.AgentRegistryTest do
  use Orchestrator.DataCase

  # This test module uses Repo directly and debug_load_agents, skip in memory mode
  @moduletag :postgres_only

  alias Orchestrator.Agent.Store, as: AgentStore
  alias Orchestrator.Schema.Agent, as: AgentSchema

  setup do
    prev_agents = Application.get_env(:orchestrator, :agents)
    prev_agents_file = Application.get_env(:orchestrator, :agents_file)

    Application.put_env(:orchestrator, :agents_file, nil)

    Application.put_env(:orchestrator, :agents, %{
      "code-reviewer" => %{
        "url" => "https://code.example.com/a2a/rpc",
        "bearer" => "CODE_API_TOKEN"
      }
    })

    Orchestrator.Repo.delete_all(AgentSchema)

    on_exit(fn ->
      Application.put_env(:orchestrator, :agents, prev_agents)
      Application.put_env(:orchestrator, :agents_file, prev_agents_file)
    end)

    :ok
  end

  test "loads config agents without explicit id using map key" do
    agents = AgentStore.debug_load_agents()
    agent = Map.fetch!(agents, "code-reviewer")

    assert agent["id"] == "code-reviewer"
    assert agent["url"] == "https://code.example.com/a2a/rpc"
    assert agent["bearer"] == "CODE_API_TOKEN"
  end
end
