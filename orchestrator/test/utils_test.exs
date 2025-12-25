defmodule Orchestrator.UtilsTest do
  @moduledoc """
  Tests for Orchestrator.Utils - shared utility functions.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Utils

  describe "new_id/0" do
    test "generates unique IDs" do
      id1 = Utils.new_id()
      id2 = Utils.new_id()

      assert is_binary(id1)
      assert is_binary(id2)
      refute id1 == id2
    end

    test "generates URL-safe IDs" do
      id = Utils.new_id()

      # Should be URL-safe base64
      assert id =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "generates 11-character IDs" do
      id = Utils.new_id()

      assert String.length(id) == 11
    end
  end

  describe "terminal_state?/1" do
    test "returns true for terminal atom states" do
      assert Utils.terminal_state?(:completed) == true
      assert Utils.terminal_state?(:failed) == true
      assert Utils.terminal_state?(:canceled) == true
      assert Utils.terminal_state?(:rejected) == true
    end

    test "returns false for non-terminal atom states" do
      assert Utils.terminal_state?(:pending) == false
      assert Utils.terminal_state?(:submitted) == false
      assert Utils.terminal_state?(:working) == false
      assert Utils.terminal_state?(:input_required) == false
    end

    test "handles string states case-insensitively" do
      assert Utils.terminal_state?("completed") == true
      assert Utils.terminal_state?("COMPLETED") == true
      assert Utils.terminal_state?("Completed") == true
      assert Utils.terminal_state?("failed") == true
      assert Utils.terminal_state?("FAILED") == true
    end

    test "returns false for non-terminal string states" do
      assert Utils.terminal_state?("pending") == false
      assert Utils.terminal_state?("working") == false
    end
  end

  describe "terminal_states/0" do
    test "returns list of terminal state atoms" do
      states = Utils.terminal_states()

      assert is_list(states)
      assert :completed in states
      assert :failed in states
      assert :canceled in states
      assert :rejected in states
    end
  end

  describe "maybe_put/3" do
    test "adds key when value is not nil" do
      result = Utils.maybe_put(%{a: 1}, :b, 2)

      assert result == %{a: 1, b: 2}
    end

    test "skips key when value is nil" do
      result = Utils.maybe_put(%{a: 1}, :b, nil)

      assert result == %{a: 1}
    end

    test "adds key with falsy values like false or 0" do
      result =
        %{}
        |> Utils.maybe_put(:a, false)
        |> Utils.maybe_put(:b, 0)
        |> Utils.maybe_put(:c, "")

      assert result == %{a: false, b: 0, c: ""}
    end
  end

  describe "maybe_put_truthy/3" do
    test "adds key when value is truthy" do
      result = Utils.maybe_put_truthy(%{a: 1}, :b, 2)

      assert result == %{a: 1, b: 2}
    end

    test "skips key when value is nil" do
      result = Utils.maybe_put_truthy(%{a: 1}, :b, nil)

      assert result == %{a: 1}
    end

    test "skips key when value is false" do
      result = Utils.maybe_put_truthy(%{a: 1}, :b, false)

      assert result == %{a: 1}
    end

    test "skips key when value is empty string" do
      result = Utils.maybe_put_truthy(%{a: 1}, :b, "")

      assert result == %{a: 1}
    end

    test "adds key with 0 (numeric zero is truthy)" do
      result = Utils.maybe_put_truthy(%{a: 1}, :b, 0)

      assert result == %{a: 1, b: 0}
    end
  end

  describe "deep_merge/2" do
    test "merges flat maps" do
      result = Utils.deep_merge(%{a: 1}, %{b: 2})

      assert result == %{a: 1, b: 2}
    end

    test "recursively merges nested maps" do
      left = %{a: %{b: 1, c: 2}}
      right = %{a: %{c: 3, d: 4}}

      result = Utils.deep_merge(left, right)

      assert result == %{a: %{b: 1, c: 3, d: 4}}
    end

    test "right side wins for non-map values" do
      left = %{a: 1, b: %{x: 1}}
      right = %{a: 2, b: "string"}

      result = Utils.deep_merge(left, right)

      assert result == %{a: 2, b: "string"}
    end

    test "handles deeply nested maps" do
      left = %{a: %{b: %{c: %{d: 1}}}}
      right = %{a: %{b: %{c: %{e: 2}}}}

      result = Utils.deep_merge(left, right)

      assert result == %{a: %{b: %{c: %{d: 1, e: 2}}}}
    end
  end

  describe "now_iso8601/0" do
    test "returns ISO8601 formatted datetime string" do
      result = Utils.now_iso8601()

      assert is_binary(result)
      # Should be parseable as datetime
      assert {:ok, _, _} = DateTime.from_iso8601(result)
    end

    test "returns UTC time" do
      result = Utils.now_iso8601()

      # Should end with Z (UTC)
      assert String.ends_with?(result, "Z")
    end
  end

  describe "now_unix_ms/0" do
    test "returns Unix timestamp in milliseconds" do
      result = Utils.now_unix_ms()

      assert is_integer(result)
      # Should be a reasonable timestamp (after 2020)
      assert result > 1_577_836_800_000
    end

    test "returns current time" do
      before = System.system_time(:millisecond)
      result = Utils.now_unix_ms()
      after_ = System.system_time(:millisecond)

      assert result >= before
      assert result <= after_
    end
  end
end
