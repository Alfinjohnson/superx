defmodule Orchestrator.Agent.Loader do
  @moduledoc """
  Loads agents from configuration sources on startup.

  Sources:
  1. YAML file (agents.yml) - Primary source for agent definitions
  2. Application config (:orchestrator, :agents) - For inline config
  3. Environment variables (A2A_REMOTE_URL) - Legacy single-agent support
  4. MCP Registry JSON files - For MCP server discovery

  ## Agent Configuration Format

  ### A2A Agents (default)
      my_agent:
        url: http://localhost:8000/a2a
        protocol: a2a
        protocolVersion: 0.3.0

  ### MCP Agents
      exa_search:
        protocol: mcp
        protocolVersion: 2024-11-05
        transport:
          type: streamable-http  # or: stdio, sse
          url: https://mcp.exa.ai/mcp
          headers:
            Authorization: Bearer ${EXA_API_KEY}

      local_mcp_server:
        protocol: mcp
        transport:
          type: stdio
          command: npx
          args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/dir"]
  """

  require Logger

  alias Orchestrator.Agent.Store

  @doc """
  Load agents from all configured sources.
  Called on application startup.
  """
  def load_all do
    # 1. Load from YAML file
    yaml_count = load_from_yaml()

    # 2. Load from application config
    config_count = load_from_config()

    # 3. Load from environment variable (legacy)
    env_count = load_from_env()

    # 4. Load from MCP registry file (if configured)
    mcp_count = load_from_mcp_registry()

    total = yaml_count + config_count + env_count + mcp_count

    Logger.info(
      "Agent loader: loaded #{total} agents (yaml: #{yaml_count}, config: #{config_count}, env: #{env_count}, mcp: #{mcp_count})"
    )

    {:ok, total}
  end

  defp load_from_yaml do
    case Application.get_env(:orchestrator, :agents_file) do
      nil ->
        Logger.debug("No AGENTS_FILE configured, skipping YAML loading")
        0

      "" ->
        Logger.debug("AGENTS_FILE is empty, skipping YAML loading")
        0

      agents_file ->
        if File.exists?(agents_file) do
          case YamlElixir.read_from_file(agents_file) do
            {:ok, %{"agents" => agents}} when is_map(agents) ->
              Enum.each(agents, fn {id, config} ->
                agent =
                  config
                  |> Map.put("id", to_string(id))
                  |> normalize_agent()

                Store.upsert(agent)
                Logger.debug("Loaded agent from YAML: #{id} (protocol: #{agent["protocol"]})")
              end)

              map_size(agents)

            {:ok, _} ->
              Logger.warning("agents.yml exists but has no 'agents' key")
              0

            {:error, reason} ->
              Logger.warning("Failed to load agents.yml: #{inspect(reason)}")
              0
          end
        else
          Logger.warning("AGENTS_FILE configured but not found: #{agents_file}")
          0
        end
    end
  end

  defp load_from_config do
    agents = Application.get_env(:orchestrator, :agents, %{})

    if map_size(agents) > 0 do
      Enum.each(agents, fn {id, config} ->
        agent = Map.put(config, "id", to_string(id))
        Store.upsert(agent)
        Logger.debug("Loaded agent from config: #{id}")
      end)

      map_size(agents)
    else
      0
    end
  end

  defp load_from_env do
    case System.get_env("A2A_REMOTE_URL") do
      nil ->
        0

      url ->
        agent = %{
          "id" => "default",
          "url" => url,
          "bearer" => System.get_env("A2A_REMOTE_BEARER"),
          "protocol" => "a2a",
          "metadata" => %{"source" => "environment"}
        }

        Store.upsert(agent)
        Logger.debug("Loaded default agent from A2A_REMOTE_URL")
        1
    end
  end

  # Load MCP servers from a registry JSON file.
  # Registry format follows the MCP registry specification.
  defp load_from_mcp_registry do
    case Application.get_env(:orchestrator, :mcp_registry_file) do
      nil ->
        0

      "" ->
        0

      registry_file ->
        if File.exists?(registry_file) do
          case File.read(registry_file) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, %{"mcpServers" => servers}} when is_map(servers) ->
                  load_mcp_servers(servers)

                {:ok, _} ->
                  Logger.warning("MCP registry exists but has no 'mcpServers' key")
                  0

                {:error, reason} ->
                  Logger.warning("Failed to parse MCP registry JSON: #{inspect(reason)}")
                  0
              end

            {:error, reason} ->
              Logger.warning("Failed to read MCP registry file: #{inspect(reason)}")
              0
          end
        else
          Logger.warning("MCP_REGISTRY_FILE configured but not found: #{registry_file}")
          0
        end
    end
  end

  defp load_mcp_servers(servers) do
    Enum.each(servers, fn {id, config} ->
      agent = mcp_server_to_agent(id, config)
      Store.upsert(agent)
      Logger.debug("Loaded MCP server from registry: #{id}")
    end)

    map_size(servers)
  end

  @doc """
  Convert MCP registry server format to agent config.

  MCP Registry format:
      {
        "mcpServers": {
          "server_name": {
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path"],
            "env": {"KEY": "value"}
          }
        }
      }

  Or for HTTP:
      {
        "mcpServers": {
          "remote_server": {
            "url": "https://mcp.example.com",
            "transport": {"type": "streamable-http"}
          }
        }
      }
  """
  def mcp_server_to_agent(id, config) do
    transport = build_transport_config(config)

    %{
      "id" => to_string(id),
      "protocol" => "mcp",
      "protocolVersion" => config["protocolVersion"] || "2024-11-05",
      "transport" => transport,
      "metadata" => %{
        "source" => "mcp_registry",
        "description" => config["description"]
      }
    }
  end

  defp build_transport_config(%{"command" => command} = config) do
    # STDIO transport
    %{
      "type" => "stdio",
      "command" => command,
      "args" => config["args"] || [],
      "env" => expand_env_vars(config["env"] || %{})
    }
  end

  defp build_transport_config(%{"url" => url} = config) do
    # HTTP transport
    transport_type =
      case config["transport"] do
        %{"type" => type} -> type
        _ -> "streamable-http"
      end

    headers =
      case config["transport"] do
        %{"headers" => h} -> expand_env_vars(h)
        _ -> %{}
      end

    %{
      "type" => transport_type,
      "url" => expand_env_var(url),
      "headers" => headers
    }
  end

  defp build_transport_config(config) do
    # Try to infer from transport key
    case config["transport"] do
      %{"type" => "stdio"} = t ->
        %{
          "type" => "stdio",
          "command" => t["command"],
          "args" => t["args"] || [],
          "env" => expand_env_vars(t["env"] || %{})
        }

      %{"type" => type, "url" => url} = t when type in ["streamable-http", "sse"] ->
        %{
          "type" => type,
          "url" => expand_env_var(url),
          "headers" => expand_env_vars(t["headers"] || %{})
        }

      _ ->
        Logger.warning("Unable to determine transport config: #{inspect(config)}")
        %{"type" => "unknown"}
    end
  end

  @doc """
  Normalize an agent config, ensuring required fields and defaults.
  Handles both A2A and MCP protocol formats.
  """
  def normalize_agent(config) do
    protocol = config["protocol"] || detect_protocol(config)

    config
    |> Map.put("protocol", protocol)
    |> Map.put_new("protocolVersion", default_protocol_version(protocol))
    |> normalize_transport(protocol)
  end

  defp detect_protocol(config) do
    cond do
      Map.has_key?(config, "transport") -> "mcp"
      Map.has_key?(config, "command") -> "mcp"
      Map.has_key?(config, "url") -> "a2a"
      true -> "a2a"
    end
  end

  defp default_protocol_version("mcp"), do: "2024-11-05"
  defp default_protocol_version("a2a"), do: "0.3.0"
  defp default_protocol_version(_), do: "1.0.0"

  defp normalize_transport(config, "mcp") do
    transport =
      cond do
        Map.has_key?(config, "transport") ->
          expand_transport_env_vars(config["transport"])

        Map.has_key?(config, "command") ->
          # Top-level command/args (MCP registry format)
          %{
            "type" => "stdio",
            "command" => config["command"],
            "args" => config["args"] || [],
            "env" => expand_env_vars(config["env"] || %{})
          }

        Map.has_key?(config, "url") ->
          # Top-level URL means HTTP transport
          %{
            "type" => "streamable-http",
            "url" => expand_env_var(config["url"]),
            "headers" => expand_env_vars(config["headers"] || %{})
          }

        true ->
          Logger.warning("MCP agent missing transport config: #{config["id"]}")
          %{"type" => "unknown"}
      end

    Map.put(config, "transport", transport)
  end

  defp normalize_transport(config, _protocol), do: config

  defp expand_transport_env_vars(%{"type" => "stdio"} = transport) do
    %{
      "type" => "stdio",
      "command" => transport["command"],
      "args" => transport["args"] || [],
      "env" => expand_env_vars(transport["env"] || %{})
    }
  end

  defp expand_transport_env_vars(%{"type" => type} = transport)
       when type in ["streamable-http", "sse"] do
    %{
      "type" => type,
      "url" => expand_env_var(transport["url"]),
      "headers" => expand_env_vars(transport["headers"] || %{})
    }
  end

  defp expand_transport_env_vars(transport), do: transport

  @doc """
  Expand environment variable references in a map.
  Supports ${VAR_NAME} syntax.
  """
  def expand_env_vars(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, expand_env_var(v)} end)
  end

  def expand_env_vars(other), do: other

  @doc """
  Expand environment variable references in a string.
  Supports ${VAR_NAME} syntax.
  """
  def expand_env_var(string) when is_binary(string) do
    Regex.replace(~r/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/, string, fn _, var_name ->
      System.get_env(var_name) || ""
    end)
  end

  def expand_env_var(other), do: other
end
