defmodule Orchestrator.Agent.Worker do
  @moduledoc """
  Per-agent GenServer managing circuit breaker, concurrency limiting, and request dispatch.

  Workers are spawned on-demand via `Agent.Supervisor` and registered in a distributed
  Horde registry for cluster-wide lookup.

  ## Features

  - **Circuit Breaker**: Protects against cascading failures
  - **Concurrency Limiting**: Backpressure via max in-flight requests
  - **Distributed**: Works across cluster nodes via Horde
  - **Telemetry**: Emits events for monitoring

  ## Circuit Breaker States

  | State | Description |
  |-------|-------------|
  | `:closed` | Normal operation, requests flow through |
  | `:open` | Failures exceeded threshold, rejecting requests |
  | `:half_open` | Testing if agent recovered |

  ## Configuration (per-agent)

  - `maxInFlight` - Max concurrent requests (default: 10)
  - `failureThreshold` - Failures before opening circuit (default: 5)
  - `failureWindowMs` - Time window for counting failures (default: 30s)
  - `cooldownMs` - How long circuit stays open (default: 30s)
  """

  use GenServer
  require Logger

  alias Orchestrator.Protocol
  alias Orchestrator.Protocol.Envelope
  alias Orchestrator.Agent.Store, as: AgentStore
  alias Orchestrator.Infra.SSEClient
  alias Orchestrator.MCP.Session, as: MCPSession
  alias Orchestrator.MCP.Supervisor, as: MCPSupervisor

  # Default configuration - can be overridden via config or per-agent
  @default_max_in_flight 10
  @default_failure_threshold 5

  # Config access with fallback defaults
  defp agent_config, do: Application.get_env(:orchestrator, :agent, [])
  defp default_failure_window_ms, do: Keyword.get(agent_config(), :failure_window_ms, 30_000)
  defp default_cooldown_ms, do: Keyword.get(agent_config(), :cooldown_ms, 30_000)
  defp default_call_timeout, do: Keyword.get(agent_config(), :call_timeout, 15_000)

  defstruct [
    :agent_id,
    :agent,
    :adapter,
    :breaker_state,
    :failure_count,
    :failure_window_start,
    :last_failure_at,
    :cooldown_until,
    :in_flight,
    :max_in_flight,
    :failure_threshold,
    :failure_window_ms,
    :cooldown_ms
  ]

  @type t :: %__MODULE__{}

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(agent) do
    GenServer.start_link(__MODULE__, agent, name: via(agent["id"]))
  end

  @doc "Get the in-flight count for an agent (used for load balancing)."
  @spec in_flight(String.t()) :: non_neg_integer()
  def in_flight(agent_id) do
    case lookup(agent_id) do
      {:ok, pid} -> GenServer.call(pid, :in_flight)
      :error -> 0
    end
  end

  @doc "Make a synchronous call to an agent."
  @spec call(String.t(), Envelope.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def call(agent_id, %Envelope{} = env, timeout \\ nil) do
    timeout = timeout || default_call_timeout()

    with {:ok, _pid} <- ensure_started(agent_id) do
      GenServer.call(via(agent_id), {:call, env}, timeout)
    end
  end

  @doc "Start a streaming request to an agent."
  @spec stream(String.t(), Envelope.t(), pid(), timeout()) :: {:ok, :streaming} | {:error, term()}
  def stream(agent_id, %Envelope{} = env, reply_to, timeout \\ nil) do
    timeout = timeout || default_call_timeout()

    with {:ok, _pid} <- ensure_started(agent_id) do
      GenServer.call(via(agent_id), {:stream, env, reply_to}, timeout)
    end
  end

  @doc "Get health/status information for an agent worker."
  @spec health(String.t()) :: {:ok, map()} | {:error, term()}
  def health(agent_id) do
    with {:ok, _pid} <- ensure_started(agent_id) do
      GenServer.call(via(agent_id), :health)
    end
  end

  # -------------------------------------------------------------------
  # Server Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(agent) do
    adapter = Protocol.adapter_for_agent(agent)
    protocol = agent["protocol"] || "a2a"

    state = %__MODULE__{
      agent_id: agent["id"],
      agent: agent,
      adapter: adapter,
      breaker_state: :closed,
      failure_count: 0,
      failure_window_start: now_ms(),
      last_failure_at: nil,
      cooldown_until: nil,
      in_flight: 0,
      max_in_flight: Map.get(agent, "maxInFlight", @default_max_in_flight),
      failure_threshold: Map.get(agent, "failureThreshold", @default_failure_threshold),
      failure_window_ms: Map.get(agent, "failureWindowMs", default_failure_window_ms()),
      cooldown_ms: Map.get(agent, "cooldownMs", default_cooldown_ms())
    }

    # Start MCP session if this is an MCP agent
    if protocol == "mcp" do
      case MCPSupervisor.start_session(agent) do
        {:ok, _pid} -> Logger.debug("MCP session started for #{agent["id"]}")
        {:error, reason} -> Logger.warning("Failed to start MCP session: #{inspect(reason)}")
      end
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:call, env}, from, state) do
    case check_breaker_and_capacity(state) do
      {:ok, state} ->
        state = %{state | in_flight: state.in_flight + 1}

        Task.Supervisor.async_nolink(Orchestrator.TaskSupervisor, fn ->
          do_call(state, env)
        end)
        |> handle_async(from, state)

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:stream, env, reply_to}, from, state) do
    case check_breaker_and_capacity(state) do
      {:ok, state} ->
        state = %{state | in_flight: state.in_flight + 1}

        Task.Supervisor.async_nolink(Orchestrator.TaskSupervisor, fn ->
          do_stream(state, env, reply_to)
        end)
        |> handle_async(from, state)

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:health, _from, state) do
    health = %{
      agent_id: state.agent_id,
      breaker_state: state.breaker_state,
      in_flight: state.in_flight,
      failure_count: state.failure_count,
      last_failure_at: state.last_failure_at,
      node: node()
    }

    {:reply, {:ok, health}, state}
  end

  @impl true
  def handle_call(:in_flight, _from, state) do
    {:reply, state.in_flight, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | in_flight: max(0, state.in_flight - 1)}
    state = update_breaker_on_result(state, result)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    state = %{state | in_flight: max(0, state.in_flight - 1)}
    state = if reason != :normal, do: record_failure(state), else: state
    {:noreply, state}
  end

  # -------------------------------------------------------------------
  # Request Execution
  # -------------------------------------------------------------------

  defp do_call(state, env) do
    protocol = state.agent["protocol"] || "a2a"

    if protocol == "mcp" do
      do_mcp_call(state, env)
    else
      do_a2a_call(state, env)
    end
  end

  # MCP protocol - route through MCP.Session
  defp do_mcp_call(state, env) do
    emit_telemetry(:call_start, state, env)

    case MCPSupervisor.lookup_session(state.agent_id) do
      {:ok, session} ->
        # Map envelope method to MCP operation
        result = dispatch_mcp_method(session, env)

        case result do
          {:ok, _} = success ->
            emit_telemetry(:call_stop, state, env, %{status: 200})
            success

          {:error, reason} ->
            Logger.warning("MCP call failed", agent_id: state.agent_id, error: inspect(reason))
            emit_telemetry(:call_error, state, env, %{error: reason})
            {:error, {:mcp_error, reason}}
        end

      :error ->
        Logger.warning("MCP session not found", agent_id: state.agent_id)
        emit_telemetry(:call_error, state, env, %{error: :session_not_found})
        {:error, {:mcp_error, :session_not_found}}
    end
  end

  # Dispatch MCP method based on envelope
  defp dispatch_mcp_method(session, %Envelope{method: :call_tool, payload: payload}) do
    tool_name = payload["name"] || payload["tool"]
    arguments = payload["arguments"] || %{}
    MCPSession.call_tool(session, tool_name, arguments)
  end

  defp dispatch_mcp_method(session, %Envelope{method: :list_tools}) do
    MCPSession.list_tools(session)
  end

  defp dispatch_mcp_method(session, %Envelope{method: :read_resource, payload: payload}) do
    uri = payload["uri"]
    MCPSession.read_resource(session, uri)
  end

  defp dispatch_mcp_method(session, %Envelope{method: :list_resources}) do
    MCPSession.list_resources(session)
  end

  defp dispatch_mcp_method(session, %Envelope{method: :get_prompt, payload: payload}) do
    name = payload["name"]
    arguments = payload["arguments"] || %{}
    MCPSession.get_prompt(session, name, arguments)
  end

  defp dispatch_mcp_method(session, %Envelope{method: :list_prompts}) do
    MCPSession.list_prompts(session)
  end

  defp dispatch_mcp_method(session, %Envelope{method: method, payload: payload}) do
    # Generic request for other methods
    wire_method = Orchestrator.Protocol.Adapters.MCP.wire_method(method)
    MCPSession.request(session, wire_method, payload)
  end

  # A2A protocol - existing HTTP-based call
  defp do_a2a_call(state, env) do
    url = state.agent["url"]
    headers = build_headers(state.agent)
    request = state.adapter.build_request(env)

    emit_telemetry(:call_start, state, env)

    case Req.post(url: url, headers: headers, json: request, finch: Orchestrator.Finch) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        emit_telemetry(:call_stop, state, env, %{status: status})
        state.adapter.parse_response(body)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Agent call failed", agent_id: state.agent_id, status: status)
        emit_telemetry(:call_error, state, env, %{status: status})
        {:error, {:remote, status, body}}

      {:error, err} ->
        Logger.warning("Agent unreachable", agent_id: state.agent_id, error: inspect(err))
        emit_telemetry(:call_error, state, env, %{error: err})
        {:error, {:unreachable, err}}
    end
  end

  defp do_stream(state, env, reply_to) do
    url = state.agent["url"]

    headers =
      build_headers(state.agent) ++
        [{"accept", "text/event-stream"}, {"content-type", "application/json"}]

    request = state.adapter.build_request(env)

    emit_telemetry(:stream_start, state, env)

    {:ok, _pid} =
      SSEClient.start_link(
        url: url,
        headers: headers,
        payload: request,
        reply_to: reply_to,
        rpc_id: env.rpc_id
      )

    {:ok, :streaming}
  end

  defp handle_async(task, _from, state) do
    ref = task.ref

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        state = %{state | in_flight: max(0, state.in_flight - 1)}
        state = update_breaker_on_result(state, result)
        {:reply, result, state}
    after
      15_000 ->
        Task.shutdown(task, :brutal_kill)
        state = %{state | in_flight: max(0, state.in_flight - 1)}
        state = record_failure(state)
        {:reply, {:error, :timeout}, state}
    end
  end

  # -------------------------------------------------------------------
  # Circuit Breaker
  # -------------------------------------------------------------------

  defp check_breaker_and_capacity(state) do
    state = maybe_transition_breaker(state)

    cond do
      state.breaker_state == :open ->
        emit_telemetry(:breaker_reject, state, nil)
        {:error, :circuit_open, state}

      state.in_flight >= state.max_in_flight ->
        emit_telemetry(:backpressure_reject, state, nil)
        {:error, :too_many_requests, state}

      true ->
        {:ok, state}
    end
  end

  defp maybe_transition_breaker(%{breaker_state: :open, cooldown_until: until} = state) do
    if now_ms() >= until do
      Logger.info("Circuit breaker half-open", agent_id: state.agent_id)
      emit_telemetry(:breaker_half_open, state, nil)
      %{state | breaker_state: :half_open}
    else
      state
    end
  end

  defp maybe_transition_breaker(state), do: state

  defp update_breaker_on_result(state, {:ok, _}), do: record_success(state)
  defp update_breaker_on_result(state, {:error, _}), do: record_failure(state)

  defp record_success(%{breaker_state: :half_open} = state) do
    Logger.info("Circuit breaker closed", agent_id: state.agent_id)
    emit_telemetry(:breaker_closed, state, nil)
    %{state | breaker_state: :closed, failure_count: 0, failure_window_start: now_ms()}
  end

  defp record_success(state), do: state

  defp record_failure(state) do
    now = now_ms()

    # Reset failure count if outside window
    state =
      if now - state.failure_window_start > state.failure_window_ms do
        %{state | failure_count: 1, failure_window_start: now}
      else
        %{state | failure_count: state.failure_count + 1}
      end

    state = %{state | last_failure_at: now}

    # Open circuit if threshold exceeded
    if state.failure_count >= state.failure_threshold and state.breaker_state != :open do
      Logger.warning("Circuit breaker open",
        agent_id: state.agent_id,
        failures: state.failure_count
      )

      emit_telemetry(:breaker_open, state, nil)
      %{state | breaker_state: :open, cooldown_until: now + state.cooldown_ms}
    else
      state
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp build_headers(%{"bearer" => token}) when is_binary(token) and token != "" do
    [{"authorization", "Bearer " <> token}]
  end

  defp build_headers(_), do: []

  # Distributed registry via Horde
  defp via(agent_id) do
    {:via, Horde.Registry, {Orchestrator.Agent.Registry, {:agent_worker, agent_id}}}
  end

  defp lookup(agent_id) do
    case Horde.Registry.lookup(Orchestrator.Agent.Registry, {:agent_worker, agent_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp ensure_started(agent_id) do
    case lookup(agent_id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case AgentStore.fetch(agent_id) do
          nil -> {:error, :agent_not_found}
          agent -> Orchestrator.Agent.Supervisor.start_worker(agent)
        end
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp emit_telemetry(event, state, env, meta \\ %{}) do
    measurements = %{timestamp: System.system_time(:millisecond)}

    metadata =
      Map.merge(meta, %{
        agent_id: state.agent_id,
        task_id: env && env.task_id,
        method: env && env.method
      })

    :telemetry.execute([:orchestrator, :agent, event], measurements, metadata)
  end
end

# Backward compatibility alias
defmodule Orchestrator.AgentWorker do
  @moduledoc false
  defdelegate start_link(agent), to: Orchestrator.Agent.Worker
  defdelegate in_flight(agent_id), to: Orchestrator.Agent.Worker
  defdelegate call(agent_id, env, timeout \\ 15_000), to: Orchestrator.Agent.Worker
  defdelegate stream(agent_id, env, reply_to, timeout \\ 15_000), to: Orchestrator.Agent.Worker
  defdelegate health(agent_id), to: Orchestrator.Agent.Worker
end
