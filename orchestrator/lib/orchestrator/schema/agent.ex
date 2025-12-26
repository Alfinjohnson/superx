defmodule Orchestrator.Schema.Agent do
  @moduledoc """
  Ecto schema for agents stored in PostgreSQL.

  Maps to the `agents` table created in migrations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "agents" do
    field :url, :string
    field :bearer, :string
    field :protocol, :string, default: "a2a"
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating or updating an agent.

  ## Required fields
  - id
  - url

  ## Optional fields
  - bearer (authentication token)
  - protocol (defaults to "a2a")
  - metadata (agent card, capabilities, etc.)
  """
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:id, :url, :bearer, :protocol, :metadata])
    |> validate_required([:id, :url])
    |> validate_format(:url, ~r/^https?:\/\//, message: "must be a valid HTTP(S) URL")
    |> unique_constraint(:id, name: :agents_pkey)
    |> unique_constraint(:url)
  end

  @doc """
  Convert Ecto schema to map format expected by the application.
  """
  def to_map(%__MODULE__{} = agent) do
    %{
      "id" => agent.id,
      "url" => agent.url,
      "bearer" => agent.bearer,
      "protocol" => agent.protocol,
      "metadata" => agent.metadata || %{}
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Convert application map format to Ecto changeset attrs.
  """
  def from_map(agent_map) when is_map(agent_map) do
    %{
      id: agent_map["id"],
      url: agent_map["url"],
      bearer: agent_map["bearer"],
      protocol: agent_map["protocol"] || "a2a",
      metadata: agent_map["metadata"] || %{}
    }
  end
end
