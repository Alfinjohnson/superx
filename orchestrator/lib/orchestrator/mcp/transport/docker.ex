defmodule Orchestrator.MCP.Transport.Docker do
  @moduledoc """
  Docker/OCI support for MCP STDIO transport.

  Handles automatic image pulling and container lifecycle management
  for MCP servers distributed as Docker/OCI images.

  ## Configuration

  ```yaml
  # Direct Docker command (existing)
  transport:
    type: stdio
    command: docker
    args: ["run", "--rm", "-i", "image:tag"]

  # OCI package format (new)
  transport:
    type: stdio
    package:
      name: "docker.io/mcp/server:latest"
      registryType: oci
    env:
      API_KEY: "${API_KEY}"
  ```

  ## Features

  - Automatic image pulling if not present locally
  - Image existence checking before pull
  - Environment variable passthrough
  - Graceful container cleanup
  - Registry authentication support (future)

  ## Security Considerations

  - Images run with `--rm` to avoid container accumulation
  - No volume mounts by default (explicit opt-in required)
  - Network isolated by default
  - Resource limits recommended for production
  """

  require Logger

  @docker_command "docker"
  @pull_timeout 300_000  # 5 minutes for image pull

  @type package_config :: %{
          name: String.t(),
          registryType: String.t(),
          tag: String.t() | nil
        }

  @doc """
  Check if the transport config uses an OCI package.
  """
  @spec oci_package?(map()) :: boolean()
  def oci_package?(config) do
    case config do
      %{"package" => %{"registryType" => "oci"}} -> true
      %{package: %{registryType: "oci"}} -> true
      _ -> false
    end
  end

  @doc """
  Transform OCI package config into STDIO transport config.

  Ensures the image is available locally (pulling if necessary)
  and returns a standard STDIO config with docker command.
  """
  @spec prepare_transport(map()) :: {:ok, map()} | {:error, term()}
  def prepare_transport(config) do
    package = config["package"] || config[:package]
    image_name = package["name"] || package[:name]

    Logger.info("Preparing OCI transport for image: #{image_name}")

    with :ok <- ensure_docker_available(),
         :ok <- ensure_image_available(image_name) do
      # Build STDIO transport config
      stdio_config = build_stdio_config(image_name, config)
      {:ok, stdio_config}
    end
  end

  @doc """
  Check if Docker is available on the system.
  """
  @spec ensure_docker_available() :: :ok | {:error, :docker_not_found}
  def ensure_docker_available do
    case System.find_executable(@docker_command) do
      nil ->
        Logger.error("Docker not found in PATH")
        {:error, :docker_not_found}

      path ->
        Logger.debug("Docker found at: #{path}")
        :ok
    end
  end

  @doc """
  Ensure the image is available locally, pulling if necessary.
  """
  @spec ensure_image_available(String.t()) :: :ok | {:error, term()}
  def ensure_image_available(image_name) do
    case image_exists?(image_name) do
      true ->
        Logger.debug("Image already available: #{image_name}")
        :ok

      false ->
        Logger.info("Pulling image: #{image_name}")
        pull_image(image_name)
    end
  end

  @doc """
  Check if an image exists locally.
  """
  @spec image_exists?(String.t()) :: boolean()
  def image_exists?(image_name) do
    args = ["image", "inspect", image_name]

    case System.cmd(@docker_command, args, stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _} -> false
    end
  end

  @doc """
  Pull a Docker image from registry.
  """
  @spec pull_image(String.t()) :: :ok | {:error, term()}
  def pull_image(image_name) do
    args = ["pull", image_name]

    Logger.info("Executing: docker #{Enum.join(args, " ")}")

    # Use Task for timeout handling
    task = Task.async(fn ->
      System.cmd(@docker_command, args, stderr_to_stdout: true)
    end)

    case Task.yield(task, @pull_timeout) || Task.shutdown(task) do
      {:ok, {_output, 0}} ->
        Logger.info("Successfully pulled image: #{image_name}")
        :ok

      {:ok, {output, exit_code}} ->
        Logger.error("Failed to pull image #{image_name}: exit #{exit_code}\n#{output}")
        {:error, {:pull_failed, exit_code, output}}

      nil ->
        Logger.error("Timeout pulling image: #{image_name}")
        {:error, {:pull_timeout, image_name}}
    end
  end

  @doc """
  Build STDIO transport config from OCI package config.
  """
  @spec build_stdio_config(String.t(), map()) :: map()
  def build_stdio_config(image_name, original_config) do
    env = original_config["env"] || original_config[:env] || %{}

    # Build docker run arguments
    docker_args = build_docker_args(image_name, env, original_config)

    %{
      "type" => "stdio",
      "command" => @docker_command,
      "args" => docker_args,
      "env" => %{},  # Env passed to docker run, not the command
      "_oci_image" => image_name  # Track original image for debugging
    }
  end

  @doc """
  Build docker run arguments.
  """
  @spec build_docker_args(String.t(), map(), map()) :: [String.t()]
  def build_docker_args(image_name, env, config) do
    base_args = ["run", "--rm", "-i"]

    # Add environment variables
    env_args =
      env
      |> Enum.flat_map(fn {key, value} ->
        ["-e", "#{key}=#{value}"]
      end)

    # Add network mode if specified
    network_args =
      case config["network"] || config[:network] do
        nil -> []
        network -> ["--network", network]
      end

    # Add resource limits if specified
    resource_args = build_resource_args(config)

    # Combine all arguments
    base_args ++ env_args ++ network_args ++ resource_args ++ [image_name]
  end

  defp build_resource_args(config) do
    args = []

    args =
      case config["memory"] || config[:memory] do
        nil -> args
        memory -> args ++ ["--memory", memory]
      end

    args =
      case config["cpus"] || config[:cpus] do
        nil -> args
        cpus -> args ++ ["--cpus", to_string(cpus)]
      end

    args
  end

  @doc """
  List all locally available MCP-related images.
  """
  @spec list_mcp_images() :: {:ok, [map()]} | {:error, term()}
  def list_mcp_images do
    # List images with mcp in name or label
    args = ["images", "--format", "{{json .}}"]

    case System.cmd(@docker_command, args, stderr_to_stdout: true) do
      {output, 0} ->
        images =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!/1)
          |> Enum.filter(fn img ->
            repository = img["Repository"] || ""
            String.contains?(repository, "mcp")
          end)

        {:ok, images}

      {output, code} ->
        {:error, {:docker_error, code, output}}
    end
  end

  @doc """
  Remove an image by name.
  """
  @spec remove_image(String.t()) :: :ok | {:error, term()}
  def remove_image(image_name) do
    args = ["rmi", image_name]

    case System.cmd(@docker_command, args, stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info("Removed image: #{image_name}")
        :ok

      {output, code} ->
        Logger.warning("Failed to remove image #{image_name}: #{output}")
        {:error, {:remove_failed, code, output}}
    end
  end

  @doc """
  Get image details including size and creation time.
  """
  @spec inspect_image(String.t()) :: {:ok, map()} | {:error, term()}
  def inspect_image(image_name) do
    args = ["image", "inspect", image_name, "--format", "{{json .}}"]

    case System.cmd(@docker_command, args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, Jason.decode!(String.trim(output))}

      {output, code} ->
        {:error, {:inspect_failed, code, output}}
    end
  end
end
