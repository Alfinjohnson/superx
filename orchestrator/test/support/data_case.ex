defmodule Orchestrator.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Orchestrator.DataCase
      import Orchestrator.Factory
    end
  end

  setup _tags do
    # Memory mode: ETS tables are managed by the stores
    # No special cleanup needed as tests use fresh app state
    :ok
  end

  @doc """
  Generates a unique ID for test data.
  """
  def unique_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @doc """
  Setup persistence for tests. In memory-only mode, this is a no-op.
  """
  def setup_persistence(_tags) do
    :ok
  end
end
