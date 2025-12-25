defmodule OrchestratorTest do
  @moduledoc """
  Tests for root Orchestrator module.
  """
  use ExUnit.Case, async: true

  describe "new_id/0" do
    test "delegates to Utils.new_id/0" do
      id = Orchestrator.new_id()

      assert is_binary(id)
      assert String.length(id) == 11
    end
  end

  describe "terminal_state?/1" do
    test "delegates to Utils.terminal_state?/1" do
      assert Orchestrator.terminal_state?(:completed) == true
      assert Orchestrator.terminal_state?(:pending) == false
      assert Orchestrator.terminal_state?("failed") == true
    end
  end
end
