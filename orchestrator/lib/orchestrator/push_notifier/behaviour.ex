defmodule Orchestrator.PushNotifier.Behaviour do
  @moduledoc """
  Behaviour for push notification operations.
  Used for mocking in tests.
  """

  @callback notify(String.t(), map()) :: :ok | {:error, term()}
  @callback notify_async(String.t(), map()) :: :ok
end
