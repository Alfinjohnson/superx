defmodule Orchestrator.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  Uses Ecto.Adapters.SQL.Sandbox for database isolation between tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      import Orchestrator.DataCase
      import Orchestrator.Factory

      alias Orchestrator.Repo
    end
  end

  setup tags do
    setup_persistence(tags)
  end

  @doc """
  Ensure persistence processes are running and checkout a sandbox owner.

  Used by both DataCase tests and ConnCase tests.
  """
  def setup_persistence(_tags) do
    # Start the application (Repo + caches + pubsub) if not already running
    {:ok, _} = Application.ensure_all_started(:orchestrator)

    # Check out a connection for this test - shared mode already set in test_helper
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Orchestrator.Repo)

    :ok
  end

  @doc """
  Generates a unique ID for test data.
  """
  def unique_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp ensure_started(module) do
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
  end
end
