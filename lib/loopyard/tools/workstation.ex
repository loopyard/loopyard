defmodule Loopyard.Tools.Workstation do
  @moduledoc """
  MCP toolkit for the **workstation agent** — the singleton agent on the
  Workstation page that configures the user's base image conversationally.

  Unlike `Tools.Container` (which acts on a workspace's code volume), these
  tools act on the workstation's *image definition*: the Dockerfile under
  `<LOOPYARD_HOME>/workstation/` and the long-lived `loopyard-workstation`
  console container. Backed entirely by `Loopyard.Workstation.Image` /
  `Loopyard.Workstation.Container`.

    * `read_dockerfile`  — see the current image definition.
    * `write_dockerfile` — replace it (the editor on the page reflects the change).
    * `rebuild_image`    — rebuild; output streams to the page's build pane.
    * `console`          — run a command in the live workstation container, e.g.
      to test an install before baking it into the Dockerfile.

  There is one workstation, so these don't take a workspace/container param —
  the targets are fixed. The session-bound `agent_id` check still applies
  (`Loopyard.Tool.authorize_agent/2`).
  """
  alias Loopyard.Tools.Workstation, as: W

  @tools [W.ReadDockerfile, W.WriteDockerfile, W.RebuildImage, W.Console]

  def __tool_server__, do: %{name: "loopyard-workstation", tools: @tools}
end
