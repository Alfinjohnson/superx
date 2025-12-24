defmodule Orchestrator.Protocol.MCP.Supervisor do
  @moduledoc """
  Supervisor for MCP sessions and related processes.

  Manages:
  - MCP session registry
  - Individual MCP session processes
  - Session supervision with restart strategies
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Registry for MCP sessions
      {Registry, keys: :unique, name: Orchestrator.MCP.SessionRegistry},

      # Dynamic supervisor for session processes
      {DynamicSupervisor, name: Orchestrator.MCP.SessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc """
  Start an MCP session for a server configuration.
  """
  @spec start_session(map()) :: {:ok, pid()} | {:error, term()}
  def start_session(server_config) do
    server_id = server_config["id"]

    # Check if session already exists
    case lookup_session(server_id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        spec = {Orchestrator.Protocol.MCP.Session, server_config}

        case DynamicSupervisor.start_child(Orchestrator.MCP.SessionSupervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Stop an MCP session.
  """
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(server_id) do
    case lookup_session(server_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(Orchestrator.MCP.SessionSupervisor, pid)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Lookup an MCP session by server ID.
  """
  @spec lookup_session(String.t()) :: {:ok, pid()} | :error
  def lookup_session(server_id) do
    case Registry.lookup(Orchestrator.MCP.SessionRegistry, server_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  List all active MCP sessions.
  """
  @spec list_sessions() :: [%{server_id: String.t(), pid: pid()}]
  def list_sessions do
    Registry.select(Orchestrator.MCP.SessionRegistry, [
      {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.map(fn {server_id, pid} -> %{server_id: server_id, pid: pid} end)
  end
end

# Backward compatibility alias
defmodule Orchestrator.MCP.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    Orchestrator.Protocol.MCP.Supervisor.start_link(opts)
  end

  @impl true
  def init(opts) do
    Orchestrator.Protocol.MCP.Supervisor.init(opts)
  end

  defdelegate start_session(server_config), to: Orchestrator.Protocol.MCP.Supervisor
  defdelegate stop_session(server_id), to: Orchestrator.Protocol.MCP.Supervisor
  defdelegate lookup_session(server_id), to: Orchestrator.Protocol.MCP.Supervisor
  defdelegate list_sessions(), to: Orchestrator.Protocol.MCP.Supervisor
end
