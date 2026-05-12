defmodule Loopyard.Events.WorkspaceServices.ServicesUpdated do
  @moduledoc "Service statuses for a workspace have changed; subscribers re-read the ETS cache or ServiceStatus module to pick up the new state. `path` is the workspace directory (canonical form)."
  defstruct [:path]
end
