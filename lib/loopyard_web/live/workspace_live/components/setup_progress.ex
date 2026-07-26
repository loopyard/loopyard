defmodule LoopyardWeb.Live.WorkspaceLive.Components.SetupProgress do
  @moduledoc """
  Renders a workspace's setup progress as a step-list takeover screen.

  Shown when the workspace's `setup.phase` is anything other than
  `:ready`. Hides the normal workspace UI (chat, sidebar content area,
  file browser) until the saga completes — the workspace is operational
  but its files aren't there yet, so showing the normal UI would be
  misleading.

  Drives off of `assigns.workspace_entry.setup`. The LiveView updates
  this map in response to `Loopyard.Events.WorkspaceSetup` events.

  Renders three phases (matching `Loopyard.Workspace.Setup.phases/0`):

    * `:worktree` — host git worktree creation
    * `:volume`   — Docker volume creation
    * `:seeding`  — rsync host → volume (the slow one)

  During `:seeding`, a live progress block shows file count, bytes
  copied, transfer rate, ETA, and the current file (when available),
  driven by `Events.WorkspaceSetup.PhaseProgress` events.
  """

  use Phoenix.Component
  import LoopyardWeb.Format, only: [format_bytes: 1]

  @phases [
    %{key: :worktree, label: "Set up host git worktree"},
    %{key: :volume, label: "Create Docker volume"},
    %{key: :seeding, label: "Copy project files into workspace volume"}
  ]

  @doc """
  `setup` is the map from the workspace's `:setup` field.
  `workspace_id` is needed for the Retry button's phx-value.
  `workspace_name` is rendered as a sub-heading (e.g. branch name).
  """
  attr :setup, :map, required: true
  attr :workspace_id, :string, required: true
  attr :workspace_name, :string, default: ""

  def setup_progress(assigns) do
    assigns = assign(assigns, :phases, @phases)

    ~H"""
    <div class="flex-1 flex items-center justify-center p-8 bg-brand-paper-shade dark:bg-brand-ink">
      <div class="max-w-xl w-full space-y-6">
        <div>
          <h2 class="text-lg font-semibold text-zinc-900 dark:text-zinc-100">
            Setting up workspace
          </h2>
          <p
            :if={@workspace_name != ""}
            class="text-sm text-zinc-500 dark:text-zinc-400 mt-1 font-mono"
          >
            {@workspace_name}
          </p>
        </div>

        <ol class="space-y-4">
          <.step_row
            :for={p <- @phases}
            label={p.label}
            phase={p.key}
            current_phase={Map.get(@setup, :phase)}
            error_phase={error_phase(@setup)}
            progress={if p.key == :seeding, do: Map.get(@setup, :progress), else: nil}
          />
        </ol>

        <%= cond do %>
          <% Map.get(@setup, :phase) == :failed and Map.get(@setup, :error) -> %>
            <.error_panel error={@setup.error} workspace_id={@workspace_id} />
          <% Map.get(@setup, :phase) in [:running, :worktree, :volume, :seeding] -> %>
            <p class="text-xs text-zinc-500 dark:text-zinc-400">
              The workspace will become available as soon as setup finishes.
              You can leave this page; setup runs in the background.
            </p>
          <% true -> %>
            <p class="text-xs text-zinc-500 dark:text-zinc-400">Preparing…</p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :phase, :atom, required: true
  attr :current_phase, :atom, required: true
  attr :error_phase, :atom, default: nil
  attr :progress, :map, default: nil

  defp step_row(assigns) do
    assigns = assign(assigns, :status, step_status(assigns))

    ~H"""
    <li class="flex items-start gap-3">
      <span class="mt-0.5 flex-none">
        <%= case @status do %>
          <% :pending -> %>
            <span class="block w-4 h-4 rounded-full border border-zinc-300 dark:border-zinc-600"></span>
          <% :running -> %>
            <span class="block w-4 h-4 rounded-full border-2 border-blue-500 border-t-transparent animate-spin"></span>
          <% :complete -> %>
            <span class="block w-4 h-4 rounded-full bg-green-500 flex items-center justify-center">
              <svg class="w-3 h-3 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="3"
                  d="M5 13l4 4L19 7"
                >
                </path>
              </svg>
            </span>
          <% :failed -> %>
            <span class="block w-4 h-4 rounded-full bg-red-500 flex items-center justify-center">
              <svg class="w-3 h-3 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="3"
                  d="M6 18L18 6M6 6l12 12"
                >
                </path>
              </svg>
            </span>
        <% end %>
      </span>
      <div class="flex-1 min-w-0">
        <span class={[
          "text-sm",
          case @status do
            :pending -> "text-zinc-500 dark:text-zinc-400"
            :running -> "text-zinc-900 dark:text-zinc-100"
            :complete -> "text-zinc-700 dark:text-zinc-300"
            :failed -> "text-red-600 dark:text-red-400"
          end
        ]}>
          {@label}
        </span>
        <.progress_block :if={@status == :running and is_map(@progress)} progress={@progress} />
      </div>
    </li>
    """
  end

  attr :progress, :map, required: true

  defp progress_block(assigns) do
    ~H"""
    <div class="mt-2 space-y-1.5">
      <div
        :if={Map.get(@progress, :percent)}
        class="w-full bg-zinc-200 dark:bg-zinc-800 rounded-full h-1.5"
      >
        <div
          class="bg-blue-500 h-1.5 rounded-full transition-all"
          style={"width: #{Map.get(@progress, :percent, 0)}%"}
        >
        </div>
      </div>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-0.5 text-xs text-zinc-500 dark:text-zinc-400 font-mono">
        <span :if={files_label(@progress)}>{files_label(@progress)}</span>
        <span :if={Map.get(@progress, :bytes)}>{format_bytes(@progress.bytes)}</span>
        <span :if={Map.get(@progress, :rate_bps)}>{format_rate(@progress.rate_bps)}</span>
        <span :if={Map.get(@progress, :eta_seconds)}>
          ~{format_duration(@progress.eta_seconds)} left
        </span>
      </div>
      <p
        :if={Map.get(@progress, :current_file)}
        class="text-xs text-zinc-500 dark:text-zinc-400 font-mono truncate"
      >
        {@progress.current_file}
      </p>
    </div>
    """
  end

  attr :error, :map, required: true
  attr :workspace_id, :string, required: true

  defp error_panel(assigns) do
    ~H"""
    <div class="rounded-md border border-red-200 dark:border-red-900/50 bg-red-50 dark:bg-red-950/30 p-4 space-y-3">
      <div>
        <h3 class="text-sm font-semibold text-red-800 dark:text-red-300">
          {Map.get(@error, :why, "Setup failed")}
        </h3>
        <p :if={Map.get(@error, :consequence)} class="text-xs text-red-700 dark:text-red-400 mt-1">
          {@error.consequence}
        </p>
      </div>
      <p :if={Map.get(@error, :action)} class="text-xs text-zinc-700 dark:text-zinc-300">
        {@error.action}
      </p>
      <div class="flex gap-2">
        <button
          phx-click="retry_setup"
          phx-value-workspace-id={@workspace_id}
          class="text-xs px-3 py-1.5 rounded-md bg-blue-600 hover:bg-blue-700 text-white font-medium"
        >
          Retry
        </button>
        <button
          phx-click="remove_workspace_setup_failed"
          phx-value-workspace-id={@workspace_id}
          data-confirm="Remove this workspace? Volumes, worktree, and files will be deleted."
          class="text-xs px-3 py-1.5 rounded-md bg-zinc-200 dark:bg-zinc-700 hover:bg-zinc-300 dark:hover:bg-zinc-600 text-zinc-700 dark:text-zinc-200 font-medium"
        >
          Remove workspace
        </button>
      </div>
    </div>
    """
  end

  defp step_status(%{phase: phase, current_phase: current, error_phase: error_phase}) do
    cond do
      error_phase == phase -> :failed
      current == :ready -> :complete
      current == phase -> :running
      phase_index(phase) < phase_index(current) -> :complete
      true -> :pending
    end
  end

  defp error_phase(setup) do
    case setup do
      %{phase: :failed, error: %{phase: phase}} -> phase
      _ -> nil
    end
  end

  # Saga progresses through phases in this order. `:running` is the
  # transient state between Started and the first PhaseStarted; treat
  # it the same as :pending for ordering purposes.
  defp phase_index(:pending), do: 0
  defp phase_index(:running), do: 0
  defp phase_index(:worktree), do: 1
  defp phase_index(:volume), do: 2
  defp phase_index(:seeding), do: 3
  defp phase_index(:ready), do: 99
  defp phase_index(:failed), do: 99
  defp phase_index(_), do: 0

  # ── Format helpers ──

  defp files_label(progress) do
    case {Map.get(progress, :files_done), Map.get(progress, :files_total)} do
      {nil, _} -> nil
      {done, nil} -> "#{done} files"
      {done, total} -> "#{done} / ~#{total} files"
    end
  end

  # `format_bytes/1` is canonical in `LoopyardWeb.Format` (auto-imported
  # into every LiveView and component). We use that instead of redefining.

  defp format_rate(bps) when is_integer(bps) and bps >= 1_000_000 do
    "#{Float.round(bps / 1_000_000, 1)} MB/s"
  end

  defp format_rate(bps) when is_integer(bps) and bps >= 1_000 do
    "#{Float.round(bps / 1_000, 1)} KB/s"
  end

  defp format_rate(bps) when is_integer(bps), do: "#{bps} B/s"
  defp format_rate(_), do: ""

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 3600 do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    "#{h}h #{m}m"
  end

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 60 do
    m = div(seconds, 60)
    s = rem(seconds, 60)
    "#{m}m #{s}s"
  end

  defp format_duration(seconds) when is_integer(seconds), do: "#{seconds}s"
  defp format_duration(_), do: ""
end
