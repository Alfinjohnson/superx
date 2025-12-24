defmodule Orchestrator.MCP.Transport.STDIO do
  @moduledoc """
  STDIO transport for MCP protocol.

  Spawns a local MCP server process and communicates via stdin/stdout.
  This is the primary transport for local MCP servers installed via
  npm, pip, or Docker.

  ## Process Communication

  ```
  Orchestrator                    MCP Server Process
       |                                  |
       |-- write to stdin --------------->|
       |   {"jsonrpc":"2.0",...}          |
       |                                  |
       |<-- read from stdout -------------|
       |   {"jsonrpc":"2.0",...}          |
  ```

  ## Important Notes

  - Server process MUST NOT write anything other than JSON-RPC to stdout
  - Logging should go to stderr
  - One JSON-RPC message per line (newline-delimited)

  ## Configuration Examples

  ```yaml
  # PyPI package
  transport:
    type: stdio
    command: uvx
    args: ["mcp-server-package"]

  # npm package
  transport:
    type: stdio
    command: npx
    args: ["-y", "@company/mcp-server"]

  # Docker
  transport:
    type: stdio
    command: docker
    args: ["run", "--rm", "-i", "image:tag"]
    env:
      API_KEY: "secret"
  ```
  """

  @behaviour Orchestrator.MCP.Transport.Behaviour

  require Logger

  alias Orchestrator.Utils

  defstruct [
    :command,
    :args,
    :env,
    :port,
    :os_pid,
    :timeout,
    :buffer,
    :pending_requests,
    :receiver_pid
  ]

  @type t :: %__MODULE__{
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          port: port() | nil,
          os_pid: non_neg_integer() | nil,
          timeout: non_neg_integer(),
          buffer: binary(),
          pending_requests: map(),
          receiver_pid: pid() | nil
        }

  # -------------------------------------------------------------------
  # Behaviour Implementation
  # -------------------------------------------------------------------

  @impl true
  def connect(config) do
    command = config.command
    args = config.args || []
    env = build_env(config.env || %{})

    state = %__MODULE__{
      command: command,
      args: args,
      env: env,
      port: nil,
      os_pid: nil,
      timeout: config.timeout || 30_000,
      buffer: "",
      pending_requests: %{},
      receiver_pid: nil
    }

    # Spawn the process
    case spawn_process(state) do
      {:ok, port, os_pid} ->
        Logger.info("MCP STDIO transport started: #{command} #{Enum.join(args, " ")} (pid: #{os_pid})")
        {:ok, %{state | port: port, os_pid: os_pid}}

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  @impl true
  def send_message(state, message) do
    if is_notification?(message) do
      case write_message(state, message) do
        :ok -> {:ok, state}
        {:error, _} = err -> err
      end
    else
      request(state, message, state.timeout)
    end
  end

  @impl true
  def request(state, message, timeout) do
    message = ensure_id(message)
    request_id = message["id"]

    Logger.debug("MCP STDIO request: #{message["method"]} id=#{request_id}")

    # Write request
    case write_message(state, message) do
      :ok ->
        # Wait for response with matching ID
        wait_for_response(state, request_id, timeout)

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def start_streaming(state, receiver_pid) do
    # Set up receiver for async messages
    {:ok, %{state | receiver_pid: receiver_pid}}
  end

  @impl true
  def stop_streaming(state) do
    {:ok, %{state | receiver_pid: nil}}
  end

  @impl true
  def close(%{port: nil} = _state) do
    :ok
  end

  def close(%{port: port, os_pid: os_pid} = _state) do
    Logger.debug("Closing MCP STDIO transport (pid: #{os_pid})")

    # Try graceful shutdown first
    try do
      Port.command(port, encode_message(%{"jsonrpc" => "2.0", "method" => "shutdown"}))
    catch
      _, _ -> :ok
    end

    # Give it a moment to shut down
    Process.sleep(100)

    # Force close port
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    # Kill OS process if still running
    if os_pid do
      kill_process(os_pid)
    end

    :ok
  end

  @impl true
  def connected?(%{port: port}) when is_port(port) do
    Port.info(port) != nil
  end

  def connected?(_), do: false

  @impl true
  def info(state) do
    %{
      transport: :stdio,
      command: state.command,
      args: state.args,
      os_pid: state.os_pid,
      connected: connected?(state)
    }
  end

  # -------------------------------------------------------------------
  # Process Management
  # -------------------------------------------------------------------

  defp spawn_process(state) do
    # Build command with full path lookup
    command = find_executable(state.command)

    unless command do
      {:error, {:command_not_found, state.command}}
    else
      # Build port options
      port_opts = [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, state.args},
        {:env, state.env},
        {:line, 1_000_000}
      ]

      try do
        port = Port.open({:spawn_executable, command}, port_opts)

        # Get OS pid
        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} -> {:ok, port, os_pid}
          nil -> {:ok, port, nil}
        end
      rescue
        e -> {:error, e}
      end
    end
  end

  defp find_executable(command) do
    # Check if it's an absolute path
    if Path.type(command) == :absolute do
      if File.exists?(command), do: command, else: nil
    else
      # Search in PATH
      System.find_executable(command)
    end
  end

  defp build_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} ->
      # Expand environment variables in values
      value = expand_env_vars(v)
      {to_charlist(k), to_charlist(value)}
    end)
  end

  defp expand_env_vars(value) when is_binary(value) do
    # Replace ${VAR} and $VAR patterns
    Regex.replace(~r/\$\{([^}]+)\}|\$([A-Za-z_][A-Za-z0-9_]*)/, value, fn _, var1, var2 ->
      System.get_env(var1 || var2) || ""
    end)
  end

  defp expand_env_vars(value), do: to_string(value)

  defp kill_process(os_pid) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("taskkill", ["/F", "/PID", to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
    end
  catch
    _, _ -> :ok
  end

  # -------------------------------------------------------------------
  # Message I/O
  # -------------------------------------------------------------------

  defp write_message(%{port: port}, message) do
    data = encode_message(message)

    try do
      Port.command(port, data)
      :ok
    rescue
      e -> {:error, e}
    end
  end

  defp encode_message(message) do
    json = Jason.encode!(message)
    "#{json}\n"
  end

  defp wait_for_response(state, request_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_response(state, request_id, deadline)
  end

  defp do_wait_for_response(state, request_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {port, {:data, {:eol, line}}} when port == state.port ->
          handle_line(state, request_id, deadline, line)

        {port, {:data, {:noeol, chunk}}} when port == state.port ->
          # Partial line - buffer it
          new_state = %{state | buffer: state.buffer <> chunk}
          do_wait_for_response(new_state, request_id, deadline)

        {port, {:exit_status, code}} when port == state.port ->
          {:error, {:process_exited, code}}
      after
        min(remaining, 1000) ->
          do_wait_for_response(state, request_id, deadline)
      end
    end
  end

  defp handle_line(state, request_id, deadline, line) do
    full_line = state.buffer <> line
    new_state = %{state | buffer: ""}

    case Jason.decode(full_line) do
      {:ok, %{"id" => ^request_id} = response} ->
        # This is our response
        {:ok, new_state, response}

      {:ok, %{"id" => _other_id} = response} ->
        # Response for a different request - might happen with concurrent requests
        Logger.debug("Received response for different request: #{inspect(response)}")
        do_wait_for_response(new_state, request_id, deadline)

      {:ok, %{"method" => _} = notification} ->
        # Server notification - forward to receiver if set
        if new_state.receiver_pid do
          send(new_state.receiver_pid, {:mcp_message, notification})
        end

        do_wait_for_response(new_state, request_id, deadline)

      {:ok, other} ->
        Logger.warning("Unexpected message from MCP server: #{inspect(other)}")
        do_wait_for_response(new_state, request_id, deadline)

      {:error, _} ->
        # Not JSON - might be logging output
        Logger.debug("Non-JSON output from MCP server: #{full_line}")
        do_wait_for_response(new_state, request_id, deadline)
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp is_notification?(message) do
    not Map.has_key?(message, "id")
  end

  defp ensure_id(%{"id" => _} = message), do: message
  defp ensure_id(message), do: Map.put(message, "id", Utils.new_id())
end
