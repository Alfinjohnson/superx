defmodule Orchestrator.Protocol.MCP.Session do
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

  alias Orchestrator.Protocol.MCP.Transport.Behaviour, as: Transport
  alias Orchestrator.Protocol.MCP.Adapter, as: MCPAdapter
  alias Orchestrator.Utils

  # Telemetry event prefix
  @telemetry_prefix [:orchestrator, :mcp]

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
  Get a synthesized agent card for this MCP server.

  Returns an agent card compatible with A2A discovery format,
  built from the MCP server's capabilities, tools, resources, and prompts.
  """
  @spec get_agent_card(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def get_agent_card(session) do
    GenServer.call(session, :get_agent_card)
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

    # Parse transport config (may pull Docker images for OCI packages)
    case Transport.parse_config(server_config) do
      {:ok, transport_config} ->
        init_with_transport(server_id, server_config, transport_config)

      {:error, reason} ->
        Logger.error("Failed to initialize MCP session #{server_id}: #{inspect(reason)}")
        {:stop, {:transport_init_failed, reason}}
    end
  end

  defp init_with_transport(server_id, server_config, transport_config) do
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

    # Emit session start telemetry
    emit_telemetry(:session_start, %{}, %{
      server_id: server_id,
      transport_type: transport_config.type
    })

    # Start connection asynchronously
    send(self(), {:connect, transport_config})

    {:ok, state}
  end

  @impl true
  def handle_call({:call_tool, tool_name, arguments}, from, state) do
    case ensure_ready(state) do
      :ok ->
        start_time = System.monotonic_time(:millisecond)
        request = MCPAdapter.build_tool_call(tool_name, arguments)
        # Store start time for telemetry on response
        request_with_meta =
          Map.put(request, :_meta, %{
            start_time: start_time,
            tool_name: tool_name,
            type: :tool_call
          })

        send_request(state, request_with_meta, from)

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
        start_time = System.monotonic_time(:millisecond)
        request = MCPAdapter.build_resource_read(uri)

        request_with_meta =
          Map.put(request, :_meta, %{start_time: start_time, uri: uri, type: :resource_read})

        send_request(state, request_with_meta, from)

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

  def handle_call(:get_agent_card, _from, state) do
    case ensure_ready(state) do
      :ok ->
        card = build_agent_card(state)
        {:reply, {:ok, card}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
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

    emit_telemetry(:transport_error, %{}, %{
      server_id: state.server_id,
      error: inspect(reason)
    })

    {:noreply, %{state | session_state: :closed}}
  end

  def handle_info({:mcp_closed, reason}, state) do
    Logger.info("MCP connection closed: #{inspect(reason)}")

    emit_telemetry(:session_stop, %{}, %{
      server_id: state.server_id,
      reason: inspect(reason)
    })

    {:noreply, %{state | session_state: :closed}}
  end

  @impl true
  def terminate(reason, state) do
    emit_telemetry(:session_stop, %{}, %{
      server_id: state.server_id,
      reason: inspect(reason)
    })

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
    # Extract metadata if present
    {meta, request} = Map.pop(request, :_meta, %{})
    request_id = request["id"]

    case state.transport_module.send_message(state.transport_state, request) do
      {:ok, transport_state, response} ->
        # Synchronous response - emit telemetry immediately
        emit_request_telemetry(meta, state, :ok)
        result = extract_result(response)
        {:reply, result, %{state | transport_state: transport_state}}

      {:ok, transport_state} ->
        # Async - store metadata with pending request for telemetry on response
        pending = Map.put(state.pending_requests, request_id, {from, meta})
        {:noreply, %{state | transport_state: transport_state, pending_requests: pending}}

      {:error, reason} = err ->
        emit_request_telemetry(meta, state, {:error, reason})
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

      {{from, meta}, pending} ->
        emit_request_telemetry(meta, state, :ok)
        GenServer.reply(from, {:ok, result})
        {:noreply, %{state | pending_requests: pending}}

      {from, pending} ->
        # Legacy format without meta
        GenServer.reply(from, {:ok, result})
        {:noreply, %{state | pending_requests: pending}}
    end
  end

  defp handle_server_message(%{"id" => id, "error" => error}, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        Logger.warning("Received error for unknown request: #{id}")
        {:noreply, state}

      {{from, meta}, pending} ->
        emit_request_telemetry(meta, state, {:error, error})
        GenServer.reply(from, {:error, error})
        {:noreply, %{state | pending_requests: pending}}

      {from, pending} ->
        # Legacy format without meta
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
    emit_telemetry(:sampling_request, %{}, %{
      server_id: state.server_id,
      direction: :incoming
    })

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

  # -------------------------------------------------------------------
  # Agent Card Synthesis
  # -------------------------------------------------------------------

  defp build_agent_card(state) do
    server_name = get_in(state.server_info, ["name"]) || state.server_id
    server_version = get_in(state.server_info, ["version"]) || "1.0.0"

    # Build skills from tools
    skills =
      (state.tools || [])
      |> Enum.map(fn tool ->
        %{
          "id" => tool["name"],
          "name" => tool["name"],
          "description" => tool["description"] || "",
          "tags" => ["mcp", "tool"],
          "examples" => build_tool_examples(tool)
        }
      end)

    # Build capabilities from MCP capabilities
    capabilities = build_capabilities_map(state.capabilities)

    %{
      "name" => server_name,
      "version" => server_version,
      "protocol" => "mcp",
      "protocolVersion" => "2024-11-05",
      "description" => build_description(state),
      "url" => nil,
      "capabilities" => capabilities,
      "defaultInputModes" => ["application/json"],
      "defaultOutputModes" => ["application/json"],
      "skills" => skills,
      "metadata" => %{
        "mcp" => %{
          "server_info" => state.server_info,
          "tools_count" => length(state.tools || []),
          "resources_count" => length(state.resources || []),
          "prompts_count" => length(state.prompts || []),
          "resources" => build_resource_summary(state.resources),
          "prompts" => build_prompt_summary(state.prompts)
        }
      }
    }
  end

  defp build_description(state) do
    tool_count = length(state.tools || [])
    resource_count = length(state.resources || [])
    prompt_count = length(state.prompts || [])

    parts = []
    parts = if tool_count > 0, do: parts ++ ["#{tool_count} tools"], else: parts
    parts = if resource_count > 0, do: parts ++ ["#{resource_count} resources"], else: parts
    parts = if prompt_count > 0, do: parts ++ ["#{prompt_count} prompts"], else: parts

    server_name = get_in(state.server_info, ["name"]) || state.server_id

    case parts do
      [] -> "MCP server: #{server_name}"
      _ -> "MCP server: #{server_name} with #{Enum.join(parts, ", ")}"
    end
  end

  defp build_capabilities_map(nil), do: %{}

  defp build_capabilities_map(caps) do
    %{
      "streaming" => false,
      "pushNotifications" => false,
      "stateTransitionHistory" => false,
      "mcp" => %{
        "tools" => caps.capabilities.tools || false,
        "resources" => caps.capabilities.resources || false,
        "prompts" => caps.capabilities.prompts || false,
        "logging" => caps.capabilities.logging || false,
        "sampling" => caps.client_requirements.sampling || false,
        "roots" => caps.client_requirements.roots || false
      }
    }
  end

  defp build_tool_examples(%{"inputSchema" => schema}) when is_map(schema) do
    # Generate example from JSON schema
    case schema do
      %{"properties" => props} when is_map(props) ->
        example =
          Enum.map(props, fn {key, prop} ->
            value = generate_example_value(prop)
            {key, value}
          end)
          |> Map.new()

        [Jason.encode!(example)]

      _ ->
        []
    end
  end

  defp build_tool_examples(_), do: []

  defp generate_example_value(%{"type" => "string"}), do: "example"
  defp generate_example_value(%{"type" => "number"}), do: 0
  defp generate_example_value(%{"type" => "integer"}), do: 0
  defp generate_example_value(%{"type" => "boolean"}), do: true
  defp generate_example_value(%{"type" => "array"}), do: []
  defp generate_example_value(%{"type" => "object"}), do: %{}
  defp generate_example_value(_), do: nil

  defp build_resource_summary(nil), do: []

  defp build_resource_summary(resources) do
    Enum.map(resources, fn r ->
      %{
        "uri" => r["uri"],
        "name" => r["name"],
        "mimeType" => r["mimeType"]
      }
    end)
  end

  defp build_prompt_summary(nil), do: []

  defp build_prompt_summary(prompts) do
    Enum.map(prompts, fn p ->
      %{
        "name" => p["name"],
        "description" => p["description"],
        "arguments" => p["arguments"]
      }
    end)
  end

  defp do_close(state) do
    if state.transport_state do
      # Try to send shutdown
      shutdown = %{"jsonrpc" => "2.0", "method" => "shutdown"}

      try do
        state.transport_module.send_message(state.transport_state, shutdown)
      catch
        _, _ -> :ok
      end

      state.transport_module.close(state.transport_state)
    end

    %{state | session_state: :closed, transport_state: nil}
  end

  # -------------------------------------------------------------------
  # Telemetry Helpers
  # -------------------------------------------------------------------

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(
      @telemetry_prefix ++ [event],
      Map.merge(%{timestamp: System.system_time(:millisecond)}, measurements),
      metadata
    )
  end

  defp emit_request_telemetry(
         %{type: :tool_call, start_time: start_time, tool_name: tool_name},
         state,
         result
       ) do
    duration_ms = System.monotonic_time(:millisecond) - start_time
    status = if match?(:ok, result), do: :ok, else: :error

    emit_telemetry(:tool_call, %{duration_ms: duration_ms}, %{
      server_id: state.server_id,
      tool_name: tool_name,
      status: status
    })
  end

  defp emit_request_telemetry(
         %{type: :resource_read, start_time: start_time, uri: uri},
         state,
         result
       ) do
    duration_ms = System.monotonic_time(:millisecond) - start_time
    status = if match?(:ok, result), do: :ok, else: :error

    emit_telemetry(:resource_read, %{duration_ms: duration_ms}, %{
      server_id: state.server_id,
      uri: uri,
      status: status
    })
  end

  defp emit_request_telemetry(_meta, _state, _result), do: :ok
end

# Backward compatibility alias
defmodule Orchestrator.MCP.Session do
  @moduledoc false
  defdelegate start_link(server_config, opts \\ []), to: Orchestrator.Protocol.MCP.Session

  defdelegate call_tool(session, tool_name, arguments \\ %{}, timeout \\ 30_000),
    to: Orchestrator.Protocol.MCP.Session

  defdelegate list_tools(session, timeout \\ 30_000), to: Orchestrator.Protocol.MCP.Session

  defdelegate read_resource(session, uri, timeout \\ 30_000),
    to: Orchestrator.Protocol.MCP.Session

  defdelegate list_resources(session, timeout \\ 30_000), to: Orchestrator.Protocol.MCP.Session

  defdelegate get_prompt(session, prompt_name, arguments \\ %{}, timeout \\ 30_000),
    to: Orchestrator.Protocol.MCP.Session

  defdelegate list_prompts(session, timeout \\ 30_000), to: Orchestrator.Protocol.MCP.Session

  defdelegate request(session, method, params \\ %{}, timeout \\ 30_000),
    to: Orchestrator.Protocol.MCP.Session

  defdelegate info(session), to: Orchestrator.Protocol.MCP.Session
  defdelegate get_agent_card(session), to: Orchestrator.Protocol.MCP.Session
  defdelegate close(session), to: Orchestrator.Protocol.MCP.Session
end
