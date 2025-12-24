defmodule Orchestrator.MCP.ClientHandler do
  @moduledoc """
  Handles bidirectional MCP requests (server → client).

  MCP allows servers to send requests back to the client for:
  - `sampling/createMessage` - Request LLM completions
  - `roots/list` - Request workspace root directories
  - `elicitation/create` - Request user input

  This module routes these requests to appropriate handlers and
  sends responses back to the MCP server.

  ## Usage

  The ClientHandler is started as part of the MCP session and receives
  server-initiated requests via messages:

  ```elixir
  # Sampling request from server
  {:mcp_sampling_request, params}

  # Roots request from server
  {:mcp_roots_request, request_id, params}

  # Elicitation request from server
  {:mcp_elicitation_request, request_id, params}
  ```

  ## Configuration

  Configure the LLM provider for sampling requests:

  ```elixir
  config :orchestrator, Orchestrator.MCP.ClientHandler,
    sampling_provider: :openai,
    sampling_model: "gpt-4",
    sampling_api_key: System.get_env("OPENAI_API_KEY")
  ```
  """

  use GenServer

  require Logger

  defstruct [
    :session_pid,
    :sampling_config,
    :roots,
    :elicitation_handler
  ]

  @type t :: %__MODULE__{
          session_pid: pid(),
          sampling_config: map() | nil,
          roots: [map()],
          elicitation_handler: (map() -> {:ok, map()} | {:error, term()}) | nil
        }

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Start a client handler linked to an MCP session.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Set the workspace roots for roots/list responses.
  """
  @spec set_roots(GenServer.server(), [map()]) :: :ok
  def set_roots(handler, roots) do
    GenServer.call(handler, {:set_roots, roots})
  end

  @doc """
  Get current roots.
  """
  @spec get_roots(GenServer.server()) :: [map()]
  def get_roots(handler) do
    GenServer.call(handler, :get_roots)
  end

  @doc """
  Configure sampling (LLM) settings.
  """
  @spec configure_sampling(GenServer.server(), map()) :: :ok
  def configure_sampling(handler, config) do
    GenServer.call(handler, {:configure_sampling, config})
  end

  @doc """
  Set custom elicitation handler function.
  """
  @spec set_elicitation_handler(GenServer.server(), (map() -> {:ok, map()} | {:error, term()})) ::
          :ok
  def set_elicitation_handler(handler, fun) do
    GenServer.call(handler, {:set_elicitation_handler, fun})
  end

  # -------------------------------------------------------------------
  # GenServer Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(opts) do
    session_pid = Keyword.fetch!(opts, :session_pid)
    sampling_config = Keyword.get(opts, :sampling_config, default_sampling_config())
    roots = Keyword.get(opts, :roots, default_roots())

    state = %__MODULE__{
      session_pid: session_pid,
      sampling_config: sampling_config,
      roots: roots,
      elicitation_handler: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:set_roots, roots}, _from, state) do
    {:reply, :ok, %{state | roots: roots}}
  end

  def handle_call(:get_roots, _from, state) do
    {:reply, state.roots, state}
  end

  def handle_call({:configure_sampling, config}, _from, state) do
    {:reply, :ok, %{state | sampling_config: config}}
  end

  def handle_call({:set_elicitation_handler, fun}, _from, state) do
    {:reply, :ok, %{state | elicitation_handler: fun}}
  end

  @impl true
  def handle_info({:mcp_sampling_request, request_id, params}, state) do
    handle_sampling_request(request_id, params, state)
  end

  def handle_info({:mcp_roots_request, request_id, _params}, state) do
    handle_roots_request(request_id, state)
  end

  def handle_info({:mcp_elicitation_request, request_id, params}, state) do
    handle_elicitation_request(request_id, params, state)
  end

  # -------------------------------------------------------------------
  # Request Handlers
  # -------------------------------------------------------------------

  defp handle_sampling_request(request_id, params, state) do
    Logger.debug("MCP sampling request: #{inspect(params)}")
    start_time = System.monotonic_time(:millisecond)

    case state.sampling_config do
      nil ->
        emit_sampling_telemetry(start_time, nil, :error)
        send_error_response(state.session_pid, request_id, -32601, "Sampling not configured")

      config ->
        # Process sampling request asynchronously
        Task.start(fn ->
          result = do_sampling(config, params)

          case result do
            {:ok, response} ->
              emit_sampling_telemetry(start_time, config[:provider], :ok)
              send_success_response(state.session_pid, request_id, response)

            {:error, reason} ->
              emit_sampling_telemetry(start_time, config[:provider], :error)
              send_error_response(state.session_pid, request_id, -32000, inspect(reason))
          end
        end)
    end

    {:noreply, state}
  end

  defp handle_roots_request(request_id, state) do
    Logger.debug("MCP roots request")

    response = %{
      "roots" => state.roots
    }

    send_success_response(state.session_pid, request_id, response)
    {:noreply, state}
  end

  defp handle_elicitation_request(request_id, params, state) do
    Logger.debug("MCP elicitation request: #{inspect(params)}")

    case state.elicitation_handler do
      nil ->
        # No handler - return error
        send_error_response(state.session_pid, request_id, -32601, "Elicitation not supported")

      handler when is_function(handler, 1) ->
        # Process asynchronously
        Task.start(fn ->
          case handler.(params) do
            {:ok, response} ->
              send_success_response(state.session_pid, request_id, response)

            {:error, reason} ->
              send_error_response(state.session_pid, request_id, -32000, inspect(reason))
          end
        end)
    end

    {:noreply, state}
  end

  # -------------------------------------------------------------------
  # Sampling Implementation
  # -------------------------------------------------------------------

  defp do_sampling(config, params) do
    # Extract parameters from MCP sampling request
    messages = params["messages"] || []
    model_preferences = params["modelPreferences"] || %{}
    system_prompt = params["systemPrompt"]
    max_tokens = params["maxTokens"] || 1024

    # Route to configured provider
    case config[:provider] do
      :openai ->
        do_openai_sampling(config, messages, system_prompt, max_tokens, model_preferences)

      :anthropic ->
        do_anthropic_sampling(config, messages, system_prompt, max_tokens, model_preferences)

      :mock ->
        # For testing
        {:ok,
         %{
           "role" => "assistant",
           "content" => %{
             "type" => "text",
             "text" => "Mock response for: #{inspect(messages)}"
           },
           "model" => "mock-model"
         }}

      nil ->
        {:error, :no_provider_configured}

      other ->
        {:error, {:unknown_provider, other}}
    end
  end

  defp do_openai_sampling(config, messages, system_prompt, max_tokens, _preferences) do
    api_key = config[:api_key]
    model = config[:model] || "gpt-4"
    base_url = config[:base_url] || "https://api.openai.com/v1"

    # Convert MCP message format to OpenAI format
    openai_messages = convert_to_openai_messages(messages, system_prompt)

    body = %{
      "model" => model,
      "messages" => openai_messages,
      "max_tokens" => max_tokens
    }

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    case Req.post("#{base_url}/chat/completions",
           json: body,
           headers: headers,
           finch: Orchestrator.Finch
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => msg} | _]}}} ->
        {:ok,
         %{
           "role" => "assistant",
           "content" => %{
             "type" => "text",
             "text" => msg["content"]
           },
           "model" => model
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_anthropic_sampling(config, messages, system_prompt, max_tokens, _preferences) do
    api_key = config[:api_key]
    model = config[:model] || "claude-3-sonnet-20240229"
    base_url = config[:base_url] || "https://api.anthropic.com/v1"

    # Convert MCP message format to Anthropic format
    anthropic_messages = convert_to_anthropic_messages(messages)

    body =
      %{
        "model" => model,
        "messages" => anthropic_messages,
        "max_tokens" => max_tokens
      }
      |> maybe_add_system(system_prompt)

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"Content-Type", "application/json"}
    ]

    case Req.post("#{base_url}/messages",
           json: body,
           headers: headers,
           finch: Orchestrator.Finch
         ) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        {:ok,
         %{
           "role" => "assistant",
           "content" => %{
             "type" => "text",
             "text" => text
           },
           "model" => model
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp convert_to_openai_messages(messages, system_prompt) do
    # Add system message if present
    system_msgs =
      if system_prompt do
        [%{"role" => "system", "content" => system_prompt}]
      else
        []
      end

    # Convert MCP messages to OpenAI format
    user_msgs =
      Enum.map(messages, fn msg ->
        content = extract_text_content(msg["content"])
        %{"role" => msg["role"], "content" => content}
      end)

    system_msgs ++ user_msgs
  end

  defp convert_to_anthropic_messages(messages) do
    Enum.map(messages, fn msg ->
      content = extract_text_content(msg["content"])
      %{"role" => msg["role"], "content" => content}
    end)
  end

  defp extract_text_content(%{"type" => "text", "text" => text}), do: text
  defp extract_text_content(content) when is_binary(content), do: content

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.map(&extract_text_content/1)
    |> Enum.join("\n")
  end

  defp extract_text_content(_), do: ""

  defp maybe_add_system(body, nil), do: body
  defp maybe_add_system(body, system), do: Map.put(body, "system", system)

  # -------------------------------------------------------------------
  # Response Helpers
  # -------------------------------------------------------------------

  defp send_success_response(session_pid, request_id, result) do
    response = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => result
    }

    send(session_pid, {:mcp_client_response, response})
  end

  defp send_error_response(session_pid, request_id, code, message) do
    response = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "error" => %{
        "code" => code,
        "message" => message
      }
    }

    send(session_pid, {:mcp_client_response, response})
  end

  # -------------------------------------------------------------------
  # Default Configuration
  # -------------------------------------------------------------------

  defp default_sampling_config do
    # Try to load from application config
    config = Application.get_env(:orchestrator, __MODULE__, [])

    case config[:sampling_provider] do
      nil ->
        nil

      provider ->
        %{
          provider: provider,
          model: config[:sampling_model],
          api_key: config[:sampling_api_key],
          base_url: config[:sampling_base_url]
        }
    end
  end

  defp default_roots do
    # Default to current working directory
    cwd = File.cwd!()

    [
      %{
        "uri" => "file://#{cwd}",
        "name" => Path.basename(cwd)
      }
    ]
  end

  # -------------------------------------------------------------------
  # Telemetry
  # -------------------------------------------------------------------

  defp emit_sampling_telemetry(start_time, provider, status) do
    duration_ms = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:orchestrator, :mcp, :sampling_complete],
      %{duration_ms: duration_ms, timestamp: System.system_time(:millisecond)},
      %{provider: provider, status: status}
    )
  end
end
