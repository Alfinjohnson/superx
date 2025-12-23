defmodule Orchestrator do
  @moduledoc """
  Root module for the Orchestrator application.

  Delegates to `Orchestrator.Utils` for common helper functions.
  Kept for backward compatibility.
  """

  # Delegate to Utils for backward compatibility
  defdelegate new_id(), to: Orchestrator.Utils
  defdelegate terminal_state?(state), to: Orchestrator.Utils
end
