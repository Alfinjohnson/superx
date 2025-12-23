defmodule Orchestrator.Web.RpcErrors do
  @moduledoc """
  JSON-RPC 2.0 error codes and message formatting.

  ## Standard Codes (JSON-RPC 2.0)

  | Code | Meaning |
  |------|---------|
  | -32700 | Parse error |
  | -32600 | Invalid Request |
  | -32601 | Method not found |
  | -32602 | Invalid params |
  | -32603 | Internal error |

  ## Application Codes (Custom)

  | Code | Meaning |
  |------|---------|
  | -32001 | Agent not found |
  | -32002 | Circuit breaker open |
  | -32003 | Agent overloaded (backpressure) |
  | -32004 | Task not found |
  | -32010 | Resource not found (generic) |
  | -32098 | Timeout |
  | -32099 | Remote agent error |
  """

  import Plug.Conn

  # -------------------------------------------------------------------
  # Standard JSON-RPC 2.0 Error Codes
  # -------------------------------------------------------------------

  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603

  # -------------------------------------------------------------------
  # Application-Specific Error Codes
  # -------------------------------------------------------------------

  @agent_not_found -32001
  @circuit_open -32002
  @agent_overloaded -32003
  @task_not_found -32004
  @resource_not_found -32010
  @timeout -32098
  @remote_error -32099

  # -------------------------------------------------------------------
  # Public API - Error Code Accessors
  # -------------------------------------------------------------------

  def code(:parse_error), do: @parse_error
  def code(:invalid_request), do: @invalid_request
  def code(:method_not_found), do: @method_not_found
  def code(:invalid_params), do: @invalid_params
  def code(:internal_error), do: @internal_error
  def code(:agent_not_found), do: @agent_not_found
  def code(:circuit_open), do: @circuit_open
  def code(:agent_overloaded), do: @agent_overloaded
  def code(:task_not_found), do: @task_not_found
  def code(:resource_not_found), do: @resource_not_found
  def code(:timeout), do: @timeout
  def code(:remote_error), do: @remote_error

  # -------------------------------------------------------------------
  # Error Response Builders
  # -------------------------------------------------------------------

  @doc """
  Build a JSON-RPC error response map.
  """
  @spec error_response(any(), integer(), String.t(), map() | nil) :: map()
  def error_response(id, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if data, do: Map.put(error, "data", data), else: error
    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end

  @doc """
  Send a JSON-RPC error response through Plug.Conn.
  Returns the conn with response sent.
  """
  @spec send_error(Plug.Conn.t(), any(), integer(), String.t(), map() | nil) :: Plug.Conn.t()
  def send_error(conn, id, code, message, data \\ nil) do
    payload = error_response(id, code, message, data)
    send_resp(conn, 400, Jason.encode!(payload))
  end

  # -------------------------------------------------------------------
  # Error Mapping from Internal Errors
  # -------------------------------------------------------------------

  @doc """
  Map internal error tuples to RPC error responses.

  ## Examples

      iex> from_internal_error({:error, :agent_missing})
      {@agent_not_found, "Agent not found"}
  """
  @spec from_internal_error(term()) :: {integer(), String.t()}
  def from_internal_error(error)

  # Agent errors
  def from_internal_error({:error, :no_agent}), do: {@invalid_params, "agentId is required"}
  def from_internal_error({:error, :agent_missing}), do: {@agent_not_found, "Agent not found"}
  def from_internal_error({:error, :agent_not_found}), do: {@agent_not_found, "Agent not found"}

  def from_internal_error({:error, :circuit_open}),
    do: {@circuit_open, "Agent circuit breaker open"}

  def from_internal_error({:error, :too_many_requests}),
    do: {@agent_overloaded, "Agent overloaded"}

  # Task errors
  def from_internal_error({:error, :task_not_found}), do: {@task_not_found, "Task not found"}

  # Remote errors
  def from_internal_error({:error, {:remote, status, body}}) do
    {@remote_error, "Remote agent error #{status}: #{inspect(body)}"}
  end

  def from_internal_error({:error, :decode}), do: {@parse_error, "Invalid JSON from remote agent"}
  def from_internal_error({:error, :timeout}), do: {@timeout, "Agent call timed out"}

  # Pass-through remote errors
  def from_internal_error({:error, %{"code" => code, "message" => msg}}), do: {code, msg}

  # Generic fallback
  def from_internal_error({:error, other}),
    do: {@remote_error, "Unknown error: #{inspect(other)}"}

  @doc """
  Handle an internal error and send appropriate RPC response.
  """
  @spec handle_error(Plug.Conn.t(), any(), term()) :: Plug.Conn.t()
  def handle_error(conn, rpc_id, error) do
    {code, message} = from_internal_error(error)
    send_error(conn, rpc_id, code, message)
  end
end
