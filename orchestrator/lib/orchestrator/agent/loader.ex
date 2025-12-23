defmodule Orchestrator.Agent.Loader do
  @moduledoc """
  Loads agents from configuration sources on startup.

  Sources:
  1. YAML file (agents.yml) - Primary source for agent definitions
  2. Application config (:orchestrator, :agents) - For inline config
  3. Environment variables (A2A_REMOTE_URL) - Legacy single-agent support
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

    total = yaml_count + config_count + env_count

    Logger.info(
      "Agent loader: loaded #{total} agents (yaml: #{yaml_count}, config: #{config_count}, env: #{env_count})"
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
                agent = Map.put(config, "id", to_string(id))
                Store.upsert(agent)
                Logger.debug("Loaded agent from YAML: #{id}")
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
          "metadata" => %{"source" => "environment"}
        }

        Store.upsert(agent)
        Logger.debug("Loaded default agent from A2A_REMOTE_URL")
        1
    end
  end
end
