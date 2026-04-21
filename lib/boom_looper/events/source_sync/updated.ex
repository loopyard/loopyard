defmodule BoomLooper.Events.SourceSync.Updated do
  @moduledoc "Sync status for this workspace changed (running / paused / errored / stopped); `status` is the full status map exposed by SyncMonitor."
  defstruct [:workspace_id, :status]
end
