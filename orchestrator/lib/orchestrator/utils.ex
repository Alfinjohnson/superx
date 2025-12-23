defmodule Orchestrator.Utils do
  @moduledoc """
  Shared utility functions used across the orchestrator.

  ## ID Generation

  Use `new_id/0` for generating unique identifiers:

      iex> Orchestrator.Utils.new_id()
      "aB3dE5fG2h"

  ## Map Helpers

  Use `maybe_put/3` to conditionally add keys to maps:

      iex> %{} |> maybe_put(:key, nil) |> maybe_put(:other, "value")
      %{other: "value"}
  """

  @terminal_states ~w(completed failed canceled rejected)a

  # -------------------------------------------------------------------
  # ID Generation
  # -------------------------------------------------------------------

  @doc """
  Generate a URL-safe random ID (11 characters).
  Uses cryptographically secure random bytes.
  """
  @spec new_id() :: String.t()
  def new_id do
    :crypto.strong_rand_bytes(8)
    |> Base.url_encode64(padding: false)
  end

  # -------------------------------------------------------------------
  # Task State Helpers
  # -------------------------------------------------------------------

  @doc """
  Check if a task state is terminal (completed, failed, canceled, rejected).
  """
  @spec terminal_state?(atom() | String.t()) :: boolean()
  def terminal_state?(state) when is_binary(state) do
    state
    |> String.downcase()
    |> String.to_atom()
    |> terminal_state?()
  end

  def terminal_state?(state) when is_atom(state), do: state in @terminal_states

  @doc "Returns the list of terminal state atoms."
  @spec terminal_states() :: [atom()]
  def terminal_states, do: @terminal_states

  # -------------------------------------------------------------------
  # Map Helpers
  # -------------------------------------------------------------------

  @doc """
  Put a key-value pair into a map only if the value is not nil.

  ## Examples

      iex> maybe_put(%{a: 1}, :b, nil)
      %{a: 1}

      iex> maybe_put(%{a: 1}, :b, 2)
      %{a: 1, b: 2}
  """
  @spec maybe_put(map(), any(), any()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Put a key-value pair into a map only if the value is truthy.
  Unlike `maybe_put/3`, this also skips false and empty strings.
  """
  @spec maybe_put_truthy(map(), any(), any()) :: map()
  def maybe_put_truthy(map, _key, nil), do: map
  def maybe_put_truthy(map, _key, false), do: map
  def maybe_put_truthy(map, _key, ""), do: map
  def maybe_put_truthy(map, key, value), do: Map.put(map, key, value)

  @doc """
  Deep merge two maps, recursively merging nested maps.

  ## Examples

      iex> deep_merge(%{a: %{b: 1}}, %{a: %{c: 2}})
      %{a: %{b: 1, c: 2}}
  """
  @spec deep_merge(map(), map()) :: map()
  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _key, _left_val, right_val ->
        right_val
    end)
  end

  # -------------------------------------------------------------------
  # Time Helpers
  # -------------------------------------------------------------------

  @doc "Returns current UTC datetime as ISO8601 string."
  @spec now_iso8601() :: String.t()
  def now_iso8601 do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  @doc "Returns current Unix timestamp in milliseconds."
  @spec now_unix_ms() :: integer()
  def now_unix_ms do
    System.system_time(:millisecond)
  end
end
