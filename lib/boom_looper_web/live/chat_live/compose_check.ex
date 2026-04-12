defmodule BoomLooperWeb.Live.ChatLive.ComposeCheck do
  @moduledoc """
  Async compose-file check — extracted from `BoomLooperWeb.ChatLive`.

  Starts a `start_async` task that reads the workspace's code volume to
  determine whether `docker-compose.yml` and `workspace.json` exist.
  The `handle_async(:compose_check, ...)` clauses remain in the parent
  LiveView since they need to dispatch navigation and call into
  `AgentLifecycle`.
  """

  import Phoenix.LiveView, only: [start_async: 3]

  @doc """
  Kick off an async check for compose file existence. Tags the result
  with the originating action (`:index` or `:new`) so `handle_async`
  can dispatch appropriately.
  """
  def kick_compose_check(socket, origin) do
    workspace = socket.assigns.workspace
    start_async(socket, :compose_check, fn ->
      ws_id = BoomLooper.Workspace.workspace_id(workspace.path)
      volume_name = BoomLooper.Workspace.volume_name_for(ws_id)
      has_compose = match?({:ok, _},
        BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/workspace/docker-compose.yml"))
      has_workspace_json = match?({:ok, _},
        BoomLooper.Workspace.load_from_volume("code-#{ws_id}"))
      %{origin: origin, has_compose: has_compose, has_config: has_workspace_json}
    end)
  end
end
