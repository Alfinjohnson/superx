defmodule Orchestrator.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  In postgres mode, we enable the SQL sandbox so changes done to the database
  are reverted at the end of every test.

  In memory mode, ETS tables are cleared between tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Orchestrator.DataCase
      import Orchestrator.Factory
    end
  end

  setup tags do
    setup_persistence(tags)
    :ok
  end

  @doc """
  Sets up persistence based on mode and test tags.
  """
  def setup_persistence(tags) do
    if Orchestrator.Persistence.postgres?() do
      # PostgreSQL mode: use Ecto sandbox
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Orchestrator.Repo, shared: not tags[:async])
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    else
      # Memory mode: ETS tables are managed by the stores
      # No special cleanup needed as tests use fresh app state
      :ok
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
