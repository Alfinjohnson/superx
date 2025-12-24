defmodule Orchestrator.MCP.Session do
  @moduledoc """
  Stateful MCP session manager.

  Unlike A2A's request/response model, MCP maintains persistent sessions
  with capability negotiation and state management.

  ## Session Lifecycle

  1. Connect transport (HTTP or STDIO)
  2. Send `initialize` request with client capabilities
  3. Receive server capabilities and info
  4. Send `notifications/initialized` to signal ready
  5. Session active - can call tools, read resources, etc.
  6. Send `shutdown` or close transport to end session

  ## Features

  - Capability caching after initialization
  - Tool/resource/prompt list caching with change notifications
  - Request/response correlation
  - Bidirectional message handling (server → client requests)
  - Automatic reconnection on transport failure

  ## Usage

  ```elixir
  # Start session for an MCP server
  {:ok, pid} = MCP.Session.start_link(server_config)

  # Call a tool
  {:ok, result} = MCP.Session.call_tool(pid, "search", %{query: "elixir"})

  # List available tools
  {:ok, tools} = MCP.Session.list_tools(pid)
  ```
  """

  use GenServer

  require Logger

  alias Orchestrator.MCP.Transport.Behaviour, as: Transport
  alias Orchestrator.Protocol.Adapters.MCP, as: MCPAdapter
  alias Orchestrator.Utils

  defstruct [
    :server_id,
    :server_config,
    :transport_module,
    :transport_state,
    :session_state,
    :server_info,
    :capabilities,
    :tools,
    :resources,
    :prompts,
    :client_handler,
    :pending_requests
  ]

  @type session_state :: :connecting | :initializing | :ready | :closed
  @type t :: %__MODULE__{
          server_id: String.t(),
          server_config: map(),
          transport_module: module(),
          transport_state: term(),
          session_state: session_state(),
          server_info: map() | nil,
          capabilities: map() | nil,
          tools: [map()] | nil,
          resources: [map()] | nil,
          prompts: [map()] | nil,
          client_handler: pid() | nil,
          pending_requests: map()
        }

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Start an MCP session for a server.
  """
  def start_link(server_config, opts \\ []) do
    name = opts[:name] || via(server_config["id"])
    GenServer.start_link(__MODULE__, server_config, name: name)
  end

  @doc """
  Call a tool on the MCP server.
  """
  @spec call_tool(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def call_tool(session, tool_name, arguments \\ %{}, timeout \\ 30_000) do
    GenServer.call(session, {:call_tool, tool_name, arguments}, timeout)
  end

  @doc """
  List available tools.
  """
  @spec list_tools(GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(session, timeout \\ 30_000) do
    GenServer.call(session, :list_tools, timeout)
  end

  @doc """
  Read a resource.
  """
  @spec read_resource(GenServer.server(), String.t(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def read_resource(session, uri, timeout \\ 30_000) do
    GenServer.call(session, {:read_resource, uri}, timeout)
  end

  @doc """
  List available resources.
  """
  @spec list_resources(GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_resources(session, timeout \\ 30_000) do
    GenServer.call(session, :list_resources, timeout)
  end

  @doc """
  Get a prompt.
  """
  @spec get_prompt(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def get_prompt(session, prompt_name, arguments \\ %{}, timeout \\ 30_000) do
    GenServer.call(session, {:get_prompt, prompt_name, arguments}, timeout)
  end

  @doc """
  List available prompts.
  """
  @spec list_prompts(GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_prompts(session, timeout \\ 30_000) do
    GenServer.call(session, :list_prompts, timeout)
  end

  @doc """
  Send a raw JSON-RPC request.
  """
  @spec request(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def request(session, method, params \\ %{}, timeout \\ 30_000) do
    GenServer.call(session, {:request, method, params}, timeout)
  end

  @doc """
  Get session state and info.
  """
  @spec info(GenServer.server()) :: map()
  def info(session) do
    GenServer.call(session, :info)
  end

  @doc """
  Close the session.
  """
  @spec close(GenServer.server()) :: :ok
  def close(session) do
    GenServer.call(session, :close)
  end

  # -------------------------------------------------------------------
  # GenServer Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(server_config) do
    server_id = server_config["id"]
    transport_config = Transport.parse_config(server_config)
    transport_module = Transport.transport_module(transport_config.type)

    state = %__MODULE__{
      server_id: server_id,
      server_config: server_config,
      transport_module: transport_module,
      transport_state: nil,
      session_state: :connecting,
      server_info: nil,
      capabilities: nil,
      tools: nil,
      resources: nil,
      prompts: nil,
      client_handler: nil,
      pending_requests: %{}
    }

    # Start connection asynchronously
    send(self(), {:connect, transport_config})

    {:ok, state}
  end

  @impl true
  def handle_call({:call_tool, tool_name, arguments}, from, state) do
    case ensure_ready(state) do
      :ok ->
        request = MCPAdapter.build_tool_call(tool_name, arguments)
        send_request(state, request, from)

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:list_tools, from, state) do
    case ensure_ready(state) do
      :ok ->
        if state.tools do
          {:reply, {:ok, state.tools}, state}
        else
          request = build_request("tools/list", %{})
          send_request(state, request, from)
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:read_resource, uri}, from, state) do
    case ensure_ready(state) do
      :ok ->
        request = MCPAdapter.build_resource_read(uri)
        send_request(state, request, from)

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:list_resources, from, state) do
    case ensure_ready(state) do
      :ok ->
        if state.resources do
          {:reply, {:ok, state.resources}, state}
        else
          request = build_request("resources/list", %{})
          send_request(state, request, from)
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:get_prompt, prompt_name, arguments}, from, state) do
    case ensure_ready(state) do
      :ok ->
        request = build_request("prompts/get", %{"name" => prompt_name, "arguments" => arguments})
        send_request(state, request, from)

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:list_prompts, from, state) do
    case ensure_ready(state) do
      :ok ->
        if state.prompts do
          {:reply, {:ok, state.prompts}, state}
        else
          request = build_request("prompts/list", %{})
          send_request(state, request, from)
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:request, method, params}, from, state) do
    case ensure_ready(state) do
      :ok ->
        request = build_request(method, params)
        send_request(state, request, from)

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:info, _from, state) do
    info = %{
      server_id: state.server_id,
      session_state: state.session_state,
      server_info: state.server_info,
      capabilities: state.capabilities,
      tools_count: state.tools && length(state.tools),
      resources_count: state.resources && length(state.resources),
      prompts_count: state.prompts && length(state.prompts),
      transport: state.transport_module.info(state.transport_state)
    }

    {:reply, info, state}
  end

  def handle_call(:close, _from, state) do
    new_state = do_close(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({:connect, transport_config}, state) do
    case state.transport_module.connect(transport_config) do
      {:ok, transport_state} ->
        new_state = %{state | transport_state: transport_state, session_state: :initializing}
        send(self(), :initialize)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("MCP transport connection failed: #{inspect(reason)}")
        {:noreply, %{state | session_state: :closed}}
    end
  end

  def handle_info(:initialize, state) do
    # Build and send initialize request
    init_request =
      MCPAdapter.build_initialize_request(%{
        sampling: true,
        roots: true
      })

    case state.transport_module.request(state.transport_state, init_request, 30_000) do
      {:ok, transport_state, response} ->
        handle_initialize_response(response, %{state | transport_state: transport_state})

      {:error, reason} ->
        Logger.error("MCP initialize failed: #{inspect(reason)}")
        {:noreply, %{state | session_state: :closed}}
    end
  end

  def handle_info({:mcp_message, message}, state) do
    handle_server_message(message, state)
  end

  def handle_info({:mcp_error, reason}, state) do
    Logger.error("MCP transport error: #{inspect(reason)}")
    {:noreply, %{state | session_state: :closed}}
  end

  def handle_info({:mcp_closed, reason}, state) do
    Logger.info("MCP connection closed: #{inspect(reason)}")
    {:noreply, %{state | session_state: :closed}}
  end

  @impl true
  def terminate(_reason, state) do
    do_close(state)
  end

  # -------------------------------------------------------------------
  # Internal Functions
  # -------------------------------------------------------------------

  defp via(server_id) do
    {:via, Registry, {Orchestrator.MCP.SessionRegistry, server_id}}
  end

  defp ensure_ready(%{session_state: :ready}), do: :ok
  defp ensure_ready(%{session_state: state}), do: {:error, {:not_ready, state}}

  defp build_request(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => Utils.new_id(),
      "method" => method,
      "params" => params
    }
  end

  defp send_request(state, request, from) do
    request_id = request["id"]

    case state.transport_module.send(state.transport_state, request) do
      {:ok, transport_state, response} ->
        # Synchronous response
        result = extract_result(response)
        {:reply, result, %{state | transport_state: transport_state}}

      {:ok, transport_state} ->
        # Async - will get response via message
        pending = Map.put(state.pending_requests, request_id, from)
        {:noreply, %{state | transport_state: transport_state, pending_requests: pending}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  defp handle_initialize_response(%{"result" => result}, state) do
    Logger.info("MCP session initialized: #{inspect(result["serverInfo"])}")

    capabilities = MCPAdapter.parse_server_capabilities(result)

    # Send initialized notification
    initialized = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized"
    }

    case state.transport_module.send(state.transport_state, initialized) do
      {:ok, transport_state} ->
        new_state = %{
          state
          | transport_state: transport_state,
            session_state: :ready,
            server_info: result["serverInfo"],
            capabilities: capabilities
        }

        # Optionally fetch tool/resource lists
        if capabilities.capabilities.tools do
          send(self(), :fetch_tools)
        end

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to send initialized: #{inspect(reason)}")
        {:noreply, %{state | session_state: :closed}}
    end
  end

  defp handle_initialize_response(%{"error" => error}, state) do
    Logger.error("MCP initialize error: #{inspect(error)}")
    {:noreply, %{state | session_state: :closed}}
  end

  defp handle_server_message(%{"id" => id, "result" => result}, state) do
    # Response to a pending request
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        Logger.warning("Received response for unknown request: #{id}")
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, {:ok, result})
        {:noreply, %{state | pending_requests: pending}}
    end
  end

  defp handle_server_message(%{"id" => id, "error" => error}, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        Logger.warning("Received error for unknown request: #{id}")
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, {:error, error})
        {:noreply, %{state | pending_requests: pending}}
    end
  end

  defp handle_server_message(%{"method" => method} = msg, state) do
    # Notification or server request
    handle_notification(method, msg["params"], state)
  end

  defp handle_notification("notifications/tools/list_changed", _params, state) do
    Logger.debug("MCP tools list changed, refreshing")
    send(self(), :fetch_tools)
    {:noreply, %{state | tools: nil}}
  end

  defp handle_notification("notifications/resources/list_changed", _params, state) do
    Logger.debug("MCP resources list changed, refreshing")
    {:noreply, %{state | resources: nil}}
  end

  defp handle_notification("notifications/prompts/list_changed", _params, state) do
    Logger.debug("MCP prompts list changed, refreshing")
    {:noreply, %{state | prompts: nil}}
  end

  defp handle_notification("sampling/createMessage", params, state) do
    # Server requesting LLM sampling - forward to client handler
    if state.client_handler do
      send(state.client_handler, {:mcp_sampling_request, params})
    else
      Logger.warning("Received sampling request but no client handler configured")
    end

    {:noreply, state}
  end

  defp handle_notification(method, params, state) do
    Logger.debug("Unhandled MCP notification: #{method} #{inspect(params)}")
    {:noreply, state}
  end

  defp extract_result(%{"result" => result}), do: {:ok, result}
  defp extract_result(%{"error" => error}), do: {:error, error}
  defp extract_result(other), do: {:error, {:unexpected_response, other}}

  defp do_close(state) do
    if state.transport_state do
      # Try to send shutdown
      shutdown = %{"jsonrpc" => "2.0", "method" => "shutdown"}

      try do
        state.transport_module.send(state.transport_state, shutdown)
      catch
        _, _ -> :ok
      end

      state.transport_module.close(state.transport_state)
    end

    %{state | session_state: :closed, transport_state: nil}
  end
end
