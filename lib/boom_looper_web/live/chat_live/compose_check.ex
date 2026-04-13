defmodule BoomLooperWeb.Live.ChatLive.ComposeCheck do
  @moduledoc """
  Async compose-file check — extracted from `BoomLooperWeb.ChatLive`.

  Starts a `start_async` task that reads the workspace's code volume to
  determine whether `docker-compose.yml` exists. The compose file IS the
  proof that the workspace was set up — workspace.json is optional metadata.
  """

  import Phoenix.LiveView, only: [start_async: 3]

  def kick_compose_check(socket, origin) do
    workspace = socket.assigns.workspace
    start_async(socket, :compose_check, fn ->
      ws_id = BoomLooper.Workspace.workspace_id(workspace.path)
      volume_name = BoomLooper.Workspace.volume_name_for(ws_id)
      has_compose = match?({:ok, _},
        BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/workspace/docker-compose.yml"))
      %{origin: origin, has_compose: has_compose}
    end)
  end
end
