defmodule BoomLooper.Workspace.ServiceStatus.Service do
  @moduledoc """
  One service known to BoomLooper. Built by `ServiceStatus.for_workspace/1`.

  The merge from "what's defined in docker-compose.yml" + "what Docker
  says is running" produces this struct. Anything that renders services
  (sidebar, project page, system pages) pattern-matches on these fields,
  so renames here ripple to compile errors at every call site.

  Hoisted out of `BoomLooper.Workspace.ServiceStatus` so the Elixir 1.19
  parallel compiler resolves `%Service{}` references in tests reliably —
  nested structs compile as a side effect of the parent module's body
  and can race, producing `Service.__struct__/1 is undefined` errors
  under the full-suite load.

  ## Status semantics

  - `:running` — container exists AND `docker inspect .State.Running == true`
  - `:starting` — container exists, not yet running (transient)
  - `:crashed` — container exists, exit code != 0
  - `:stopped` — container doesn't exist OR exited cleanly
  """
  @enforce_keys [:name, :type, :status]
  defstruct [
    :name,
    :type,
    :status,
    :container,
    :image,
    ports: %{},
    exit_info: nil
  ]

  @type status :: :running | :starting | :crashed | :stopped
  @type t :: %__MODULE__{
          name: String.t(),
          type: :stock | :process,
          status: status(),
          container: String.t() | nil,
          image: String.t() | nil,
          ports: %{optional(integer() | String.t()) => integer() | String.t()},
          exit_info: map() | nil
        }
end
