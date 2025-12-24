# Configure ExUnit
# All tests run in memory mode (hybrid)
ExUnit.start()

# Define Mox mocks
Mox.defmock(Orchestrator.MockHttpClient, for: Orchestrator.HttpClient.Behaviour)
Mox.defmock(Orchestrator.MockPushNotifier, for: Orchestrator.PushNotifier.Behaviour)

# -------------------------------------------------------------------
# Telemetry Test Helpers
# -------------------------------------------------------------------

defmodule Orchestrator.TelemetryHelper do
  @moduledoc """
  Helpers for testing telemetry events.
  """

  @doc """
  Attach a telemetry handler that sends events to the current process.

  Returns a unique handler ID for cleanup.

  Note: The telemetry library emits a warning about local functions,
  but this is unavoidable for test handlers that need to capture the
  calling process. The warning is informational only.
  """
  def attach(event_prefix) do
    handler_id = "test-#{:erlang.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      expand_events(event_prefix),
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  @doc """
  Detach a telemetry handler by ID.
  """
  def detach(handler_id) do
    :telemetry.detach(handler_id)
  end

  defp expand_events([:orchestrator, :http | _rest] = prefix) do
    [prefix ++ [:request]]
  end

  defp expand_events([:orchestrator, :agent | _rest]) do
    [
      [:orchestrator, :agent, :call_start],
      [:orchestrator, :agent, :call_stop],
      [:orchestrator, :agent, :call_error],
      [:orchestrator, :agent, :stream_start],
      [:orchestrator, :agent, :breaker_reject],
      [:orchestrator, :agent, :backpressure_reject],
      [:orchestrator, :agent, :breaker_open],
      [:orchestrator, :agent, :breaker_closed],
      [:orchestrator, :agent, :breaker_half_open]
    ]
  end

  defp expand_events([:orchestrator, :push | _rest]) do
    [
      [:orchestrator, :push, :push_start],
      [:orchestrator, :push, :push_success],
      [:orchestrator, :push, :push_failure]
    ]
  end

  defp expand_events(prefix), do: [prefix]
end
