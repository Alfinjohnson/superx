defmodule Orchestrator.HttpClient.Behaviour do
  @moduledoc """
  Behaviour for HTTP client operations.
  Used for mocking in tests.
  """

  @callback post_json(String.t(), map(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback get_json(String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback fetch_agent_card(String.t()) ::
              {:ok, map()} | {:error, term()}
end
