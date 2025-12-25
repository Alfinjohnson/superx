defmodule Orchestrator.Web.Handlers.MCPServer do
  @moduledoc """
  Handles MCP server endpoints for external clients connecting via SSE.

  This module implements the MCP SSE transport protocol for Google ADK:
  1. Client connects to GET /sse to establish SSE stream
  2. Client sends JSON-RPC requests via POST /messages?session_id=<id>
  3. Server sends response back via the SSE stream (not HTTP response)

  MCP requests are proxied to configured MCP backend agents.
  """

  require Logger

  alias Orchestrator.Utils
  alias Orchestrator.Agent.Store, as: AgentStore
  alias Orchestrator.Agent.Worker, as: AgentWorker
  alias Orchestrator.Protocol.Envelope
  alias Orchestrator.MCP.Supervisor, as: MCPSupervisor
  alias Orchestrator.MCP.Session, as: MCPSession

  # ETS table to track SSE connections by session_id
  @sse_sessions :mcp_sse_sessions

  @doc """
  Initialize ETS table for SSE session tracking
  """
  def init do
    if :ets.whereis(@sse_sessions) == :undefined do
      :ets.new(@sse_sessions, [:named_table, :public, :set])
    end
    :ok
  end

  @doc """
  Handle SSE connection - establishes streaming connection.
  ADK connects here to receive server-sent events.
  """
  def handle_sse(conn) do
    session_id = Utils.new_id()
    Logger.info("MCP SSE connection established: #{session_id}")

    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_header("connection", "keep-alive")
      |> Plug.Conn.put_resp_header("access-control-allow-origin", "*")
      |> Plug.Conn.send_chunked(200)

    # Send initial endpoint event with session_id
    endpoint_event = "event: endpoint\ndata: /messages?session_id=#{session_id}\n\n"
    {:ok, conn} = Plug.Conn.chunk(conn, endpoint_event)

    # Register this process for the session
    :ets.insert(@sse_sessions, {session_id, self()})

    # Enter SSE loop to handle responses and keepalives
    sse_loop(conn, session_id)
  end

  @doc """
  Handle JSON-RPC message from client via POST /messages
  Sends response via SSE stream, returns 202 Accepted.
  """
  def handle_message(conn, session_id) do
    case conn.body_params do
      %{"jsonrpc" => "2.0", "method" => method} = request ->
        Logger.info("MCP request: session=#{session_id} method=#{method} id=#{request["id"]}")

        # Process request and get response
        response = handle_mcp_request(method, request)

        # Send response via SSE stream
        if response do
          send_to_sse(session_id, response)
        end

        # Return 202 Accepted (response goes via SSE)
        Plug.Conn.send_resp(conn, 202, "")

      _ ->
        error_response = %{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{"code" => -32600, "message" => "Invalid Request"}
        }

        send_to_sse(session_id, error_response)
        Plug.Conn.send_resp(conn, 202, "")
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(error_response))
    end
  end

  # -------------------------------------------------------------------
  # MCP Request Handlers
  # -------------------------------------------------------------------

  defp handle_mcp_request("initialize", request) do
    id = request["id"]

    # Return server capabilities
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{
          "tools" => %{"listChanged" => true},
          "resources" => %{"listChanged" => true},
          "prompts" => %{"listChanged" => true}
        },
        "serverInfo" => %{
          "name" => "superx-orchestrator",
          "version" => "0.1.0"
        }
      }
    }
  end

  defp handle_mcp_request("notifications/initialized", _request) do
    # Client acknowledged initialization - no response needed
    nil
  end

  defp handle_mcp_request("tools/list", request) do
    id = request["id"]

    # Get tools from all registered MCP agents
    tools = list_all_mcp_tools()

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "tools" => tools
      }
    }
  end

  defp handle_mcp_request("tools/call", request) do
    id = request["id"]
    params = request["params"] || %{}
    tool_name = params["name"]
    arguments = params["arguments"] || %{}

    Logger.info("MCP tools/call: #{tool_name} with args: #{inspect(arguments)}")

    result = call_mcp_tool(tool_name, arguments)

    case result do
      {:ok, content} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "content" => content
          }
        }

      {:error, reason} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => -32000,
            "message" => "Tool execution failed: #{inspect(reason)}"
          }
        }
    end
  end

  defp handle_mcp_request("resources/list", request) do
    id = request["id"]
    resources = list_all_mcp_resources()

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "resources" => resources
      }
    }
  end

  defp handle_mcp_request("prompts/list", request) do
    id = request["id"]

    # Return available prompts (can be extended)
    prompts = list_prompts()

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "prompts" => prompts
      }
    }
  end

  defp handle_mcp_request("prompts/get", request) do
    id = request["id"]
    params = request["params"] || %{}
    prompt_name = params["name"]

    case get_prompt(prompt_name, params["arguments"] || %{}) do
      {:ok, messages} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "messages" => messages
          }
        }

      {:error, reason} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => -32000,
            "message" => reason
          }
        }
    end
  end

  defp handle_mcp_request(method, request) do
    id = request["id"]

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32601,
        "message" => "Method not found: #{method}"
      }
    }
  end

  # -------------------------------------------------------------------
  # MCP Tool Discovery & Execution (Proxy to MCP agents)
  # -------------------------------------------------------------------

  defp list_all_mcp_tools do
    agents = AgentStore.list()

    # Collect tools from all MCP agents
    mcp_tools =
      agents
      |> Enum.filter(fn agent -> agent["protocol"] == "mcp" end)
      |> Enum.flat_map(fn agent ->
        agent_id = agent["id"]

        # Ensure MCP session is started
        session = ensure_mcp_session(agent)

        case session do
          {:ok, session_pid} ->
            case MCPSession.list_tools(session_pid, 10_000) do
              {:ok, %{"tools" => tools}} -> tools
              {:ok, tools} when is_list(tools) -> tools
              {:error, reason} ->
                Logger.warning("Failed to list tools from #{agent_id}: #{inspect(reason)}")
                []
            end

          {:error, reason} ->
            Logger.warning("MCP session not available for #{agent_id}: #{inspect(reason)}")
            []
        end
      end)

    # Also expose A2A agents as tools
    a2a_tools =
      agents
      |> Enum.filter(fn agent -> (agent["protocol"] || "a2a") == "a2a" end)
      |> Enum.flat_map(fn agent ->
        skills = get_in(agent, ["metadata", "agentCard", "skills"]) || []

        Enum.map(skills, fn skill ->
          %{
            "name" => skill["id"],
            "description" => skill["description"] || skill["name"],
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{
                "message" => %{
                  "type" => "string",
                  "description" => "The message to send to the agent"
                }
              },
              "required" => ["message"]
            }
          }
        end)
      end)

    mcp_tools ++ a2a_tools
  end

  # Ensure MCP session is started for an agent
  defp ensure_mcp_session(agent) do
    agent_id = agent["id"]

    case MCPSupervisor.lookup_session(agent_id) do
      {:ok, session} ->
        {:ok, session}

      :error ->
        Logger.info("Starting MCP session for #{agent_id}")
        case MCPSupervisor.start_session(agent) do
          {:ok, session} -> {:ok, session}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp call_mcp_tool(tool_name, arguments) do
    # Find which agent provides this tool by searching all agents
    case find_tool_agent(tool_name) do
      {:ok, agent_id, "mcp"} ->
        Logger.info("Routing tool #{tool_name} to MCP agent #{agent_id}")
        call_mcp_agent_tool(agent_id, tool_name, arguments)

      {:ok, agent_id, "a2a"} ->
        Logger.info("Routing tool #{tool_name} to A2A agent #{agent_id}")
        call_a2a_agent_tool(agent_id, tool_name, arguments)

      :not_found ->
        {:error, "Tool not found: #{tool_name}"}
    end
  end

  # Find which agent provides a tool by searching all agents
  defp find_tool_agent(tool_name) do
    agents = AgentStore.list()

    # First check MCP agents
    mcp_match =
      agents
      |> Enum.filter(fn agent -> agent["protocol"] == "mcp" end)
      |> Enum.find_value(fn agent ->
        agent_id = agent["id"]

        case ensure_mcp_session(agent) do
          {:ok, session} ->
            case MCPSession.list_tools(session, 10_000) do
              {:ok, %{"tools" => tools}} ->
                if Enum.any?(tools, fn t -> t["name"] == tool_name end) do
                  {:ok, agent_id, "mcp"}
                end

              {:ok, tools} when is_list(tools) ->
                if Enum.any?(tools, fn t -> t["name"] == tool_name end) do
                  {:ok, agent_id, "mcp"}
                end

              _ -> nil
            end

          {:error, _} -> nil
        end
      end)

    if mcp_match do
      mcp_match
    else
      # Check A2A agents
      a2a_match =
        agents
        |> Enum.filter(fn agent -> (agent["protocol"] || "a2a") == "a2a" end)
        |> Enum.find_value(fn agent ->
          agent_id = agent["id"]
          skills = get_in(agent, ["metadata", "agentCard", "skills"]) || []

          if Enum.any?(skills, fn s -> s["id"] == tool_name end) do
            {:ok, agent_id, "a2a"}
          end
        end)

      a2a_match || :not_found
    end
  end

  defp call_mcp_agent_tool(agent_id, tool_name, arguments) do
    agent = AgentStore.fetch(agent_id)

    case ensure_mcp_session(agent) do
      {:ok, session} ->
        Logger.info("Calling MCP tool #{tool_name} on #{agent_id}")

        case MCPSession.call_tool(session, tool_name, arguments, 30_000) do
          {:ok, result} ->
            # Result should have "content" array
            content = result["content"] || [%{"type" => "text", "text" => Jason.encode!(result)}]
            {:ok, content}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "MCP session not available for #{agent_id}: #{inspect(reason)}"}
    end
  end

  defp call_a2a_agent_tool(agent_id, _skill_id, arguments) do
    message_text = arguments["message"] || Jason.encode!(arguments)

    env =
      Envelope.new(%{
        method: :send_message,
        message: %{
          "messageId" => Utils.new_id(),
          "role" => "user",
          "parts" => [%{"type" => "text", "text" => message_text}]
        },
        agent_id: agent_id,
        rpc_id: Utils.new_id()
      })

    case AgentWorker.call(agent_id, env) do
      {:ok, result} ->
        text = extract_result_text(result)
        {:ok, [%{"type" => "text", "text" => text}]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_all_mcp_resources do
    agents = AgentStore.list()

    agents
    |> Enum.filter(fn agent -> agent["protocol"] == "mcp" end)
    |> Enum.flat_map(fn agent ->
      agent_id = agent["id"]

      case MCPSupervisor.lookup_session(agent_id) do
        {:ok, session} ->
          case MCPSession.list_resources(session, 10_000) do
            {:ok, %{"resources" => resources}} ->
              Enum.map(resources, fn r ->
                Map.put(r, "uri", "#{agent_id}::#{r["uri"]}")
              end)

            {:ok, resources} when is_list(resources) ->
              Enum.map(resources, fn r ->
                Map.put(r, "uri", "#{agent_id}::#{r["uri"]}")
              end)

            _ ->
              []
          end

        :error ->
          []
      end
    end)
  end

  defp extract_result_text(result) do
    # Try to extract readable text from A2A response
    cond do
      artifacts = result["artifacts"] ->
        artifacts
        |> Enum.flat_map(fn a -> a["parts"] || [] end)
        |> Enum.map(fn p -> p["text"] || inspect(p) end)
        |> Enum.join("\n")

      history = result["history"] ->
        history
        |> Enum.filter(fn m -> m["role"] == "agent" end)
        |> Enum.flat_map(fn m -> m["parts"] || [] end)
        |> Enum.map(fn p -> p["text"] || inspect(p) end)
        |> Enum.join("\n")

      true ->
        Jason.encode!(result)
    end
  end

  # -------------------------------------------------------------------
  # Prompts
  # -------------------------------------------------------------------

  defp list_prompts do
    [
      %{
        "name" => "file_system_prompt",
        "description" => "Instructions for file system operations via connected agents"
      },
      %{
        "name" => "agent_list_prompt",
        "description" => "List of available agents and their capabilities"
      }
    ]
  end

  defp get_prompt("file_system_prompt", _args) do
    agents = AgentStore.list()
    agent_list = Enum.map(agents, fn a -> "- #{a["id"]}: #{get_in(a, ["metadata", "description"]) || "No description"}" end) |> Enum.join("\n")

    {:ok,
     [
       %{
         "role" => "user",
         "content" => %{
           "type" => "text",
           "text" => """
           You are an assistant with access to the following agents via the SuperX orchestrator:

           #{agent_list}

           Use the available tools to interact with these agents. Each agent skill is exposed as a tool.
           When calling a tool, provide a clear message describing what you want the agent to do.
           """
         }
       }
     ]}
  end

  defp get_prompt("agent_list_prompt", _args) do
    agents = AgentStore.list()

    agent_info =
      Enum.map(agents, fn agent ->
        skills = get_in(agent, ["metadata", "agentCard", "skills"]) || []
        skill_text = Enum.map(skills, fn s -> "  - #{s["name"]}: #{s["description"]}" end) |> Enum.join("\n")

        """
        Agent: #{agent["id"]}
        Protocol: #{agent["protocol"] || "a2a"}
        URL: #{agent["url"]}
        Skills:
        #{skill_text}
        """
      end)
      |> Enum.join("\n---\n")

    {:ok,
     [
       %{
         "role" => "user",
         "content" => %{
           "type" => "text",
           "text" => "Available Agents:\n\n#{agent_info}"
         }
       }
     ]}
  end

  defp get_prompt(name, _args) do
    {:error, "Prompt not found: #{name}"}
  end

  # -------------------------------------------------------------------
  # SSE Session Management
  # -------------------------------------------------------------------

  # Send response to SSE stream by session_id
  defp send_to_sse(session_id, response) do
    case :ets.lookup(@sse_sessions, session_id) do
      [{^session_id, pid}] ->
        send(pid, {:mcp_response, response})
        :ok

      [] ->
        Logger.warning("SSE session not found: #{session_id}")
        :error
    end
  end

  # SSE loop - receives responses and sends them to client
  defp sse_loop(conn, session_id) do
    receive do
      {:mcp_response, response} ->
        # Send response as SSE message event
        event_data = "event: message\ndata: #{Jason.encode!(response)}\n\n"
        Logger.debug("SSE sending response to #{session_id}: #{inspect(response)}")

        case Plug.Conn.chunk(conn, event_data) do
          {:ok, conn} ->
            sse_loop(conn, session_id)

          {:error, reason} ->
            Logger.info("SSE connection error: #{inspect(reason)}")
            cleanup_session(session_id)
        end

      :close ->
        cleanup_session(session_id)
    after
      30_000 ->
        # Send keepalive ping every 30 seconds
        case Plug.Conn.chunk(conn, ": ping\n\n") do
          {:ok, conn} ->
            sse_loop(conn, session_id)

          {:error, reason} ->
            Logger.info("SSE connection ended: #{inspect(reason)}")
            cleanup_session(session_id)
        end
    end
  end

  defp cleanup_session(session_id) do
    :ets.delete(@sse_sessions, session_id)
    Logger.info("MCP SSE session cleaned up: #{session_id}")
  end
end
