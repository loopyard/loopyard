defmodule BoomLooperWeb.Components.Source.Local.SyncCard do
  @moduledoc """
  Compact status card for a Local workspace's mutagen sync session. Shows
  the current state (dot + label) and exposes restart / pause / resume.

  Consumers should subscribe to
  `BoomLooper.Source.Local.SyncMonitor.topic(workspace_id)` to re-render on
  state changes. The LiveView handles `"sync_restart"`, `"sync_pause"`, and
  `"sync_resume"` phx-click events (all with `phx-value-workspace-id`).

  This component is Local-only — GitHub workspaces should simply not render it.
  """
  use Phoenix.Component

  attr :workspace_id, :string, required: true
  attr :sync, :map,
    required: true,
    doc:
      "Status map from SyncMonitor.status/1: %{status, last_error, last_checked_at}. Safe to pass nil."

  def sync_card(assigns) do
    ~H"""
    <div class="rounded border border-zinc-200 dark:border-zinc-800 px-3 py-2 text-xs text-zinc-600 dark:text-zinc-400">
      <div class="flex items-center justify-between gap-2">
        <div class="flex items-center gap-2 min-w-0">
          <div class={"w-2 h-2 rounded-full flex-none #{dot_class(@sync)}"}></div>
          <span class="font-medium text-zinc-700 dark:text-zinc-300">Sync</span>
          <span class="truncate">{status_label(@sync)}</span>
        </div>
        <div class="flex items-center gap-1">
          <button
            type="button"
            phx-click="sync_restart"
            phx-value-workspace-id={@workspace_id}
            class="px-2 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 hover:bg-zinc-200 dark:hover:bg-zinc-700"
          >
            Restart
          </button>
          <%= if status(@sync) == :paused do %>
            <button
              type="button"
              phx-click="sync_resume"
              phx-value-workspace-id={@workspace_id}
              class="px-2 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 hover:bg-zinc-200 dark:hover:bg-zinc-700"
            >
              Resume
            </button>
          <% else %>
            <button
              type="button"
              phx-click="sync_pause"
              phx-value-workspace-id={@workspace_id}
              class="px-2 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 hover:bg-zinc-200 dark:hover:bg-zinc-700"
            >
              Pause
            </button>
          <% end %>
        </div>
      </div>
      <%= if err = error(@sync) do %>
        <div class="mt-1 text-red-500 truncate" title={err}>{err}</div>
      <% end %>
    </div>
    """
  end

  defp status(%{status: s}), do: s
  defp status(_), do: :stopped

  defp error(%{last_error: err}) when is_binary(err) and err != "", do: err
  defp error(_), do: nil

  defp dot_class(sync) do
    case status(sync) do
      :running -> "bg-emerald-500"
      :paused -> "bg-amber-400"
      :errored -> "bg-red-500"
      :starting -> "bg-blue-400 animate-pulse"
      _ -> "bg-zinc-400"
    end
  end

  defp status_label(sync) do
    case status(sync) do
      :running -> "running"
      :paused -> "paused"
      :errored -> "error"
      :starting -> "starting…"
      :stopped -> "stopped"
      other -> to_string(other)
    end
  end
end
