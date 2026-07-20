defmodule LoopyardWeb.Live.WorkspaceLive.Components.States do
  @moduledoc "State screens: booting_screen, empty_state."
  use Phoenix.Component

  def booting_screen(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <div class="text-center max-w-sm">
        <div class="w-16 h-16 rounded-2xl bg-violet-100 dark:bg-violet-900/30 flex items-center justify-center mx-auto mb-4">
          <svg
            class="w-7 h-7 text-violet-500 animate-spin"
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
          >
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
            </circle>
            <path
              class="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
            >
            </path>
          </svg>
        </div>
        <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100 mb-1">Starting agent</h3>
        <p class="text-xs text-zinc-500 dark:text-zinc-400 font-mono mb-3">{@agent_id}</p>
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-4">{@status}</p>
        <details :if={@boot_log != []} class="text-left">
          <summary class="text-xs text-zinc-500 dark:text-zinc-400 cursor-pointer hover:text-zinc-600 dark:hover:text-zinc-300">
            Boot log
          </summary>
          <div class="mt-2 bg-zinc-50 dark:bg-zinc-800 rounded-lg p-3 text-xs font-mono text-zinc-500 dark:text-zinc-400 space-y-0.5 max-h-48 overflow-y-auto">
            <p :for={line <- @boot_log}>{line}</p>
          </div>
        </details>
      </div>
    </div>
    """
  end

  # The workspace root when no agent is selected. Working is the DEFAULT
  # state (north-star D10): you don't boot containers to start working — you
  # start an agent and it works against the cheap, code-mounted work container,
  # showing its work as it goes. Booting the dev/preview cluster is a separate,
  # opt-in action (for *running* the app), demoted to a quiet secondary link.
  attr :workspace, :map, required: true
  attr :workspace_state, :atom, required: true
  attr :base_path, :string, required: true

  def workspace_not_running(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <div class="text-center max-w-md px-4">
        <div class="w-16 h-16 rounded-2xl bg-violet-100 dark:bg-violet-900/30 flex items-center justify-center mx-auto mb-4">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="currentColor"
            class="w-7 h-7 text-violet-500"
          >
            <path d="M16.5 7.5h-9v9h9v-9Z" />
            <path
              fill-rule="evenodd"
              d="M8.25 2.25A.75.75 0 0 1 9 3v.75h2.25V3a.75.75 0 0 1 1.5 0v.75H15V3a.75.75 0 0 1 1.5 0v.75h.75a3 3 0 0 1 3 3v.75H21A.75.75 0 0 1 21 9h-.75v2.25H21a.75.75 0 0 1 0 1.5h-.75V15H21a.75.75 0 0 1 0 1.5h-.75v.75a3 3 0 0 1-3 3h-.75V21a.75.75 0 0 1-1.5 0v-.75h-2.25V21a.75.75 0 0 1-1.5 0v-.75H9V21a.75.75 0 0 1-1.5 0v-.75h-.75a3 3 0 0 1-3-3v-.75H3A.75.75 0 0 1 3 15h.75v-2.25H3a.75.75 0 0 1 0-1.5h.75V9H3a.75.75 0 0 1 0-1.5h.75V6.75a3 3 0 0 1 3-3h.75V3a.75.75 0 0 1 .75-.75ZM6 6.75A.75.75 0 0 1 6.75 6h10.5a.75.75 0 0 1 .75.75v10.5a.75.75 0 0 1-.75.75H6.75a.75.75 0 0 1-.75-.75V6.75Z"
              clip-rule="evenodd"
            />
          </svg>
        </div>
        <h3 class="text-lg font-semibold mb-1">{@workspace.name}</h3>
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-6">
          Ready to work. Start an agent and it'll begin showing its work as it goes —
          no need to boot containers first.
        </p>
        <.link
          patch={"#{@base_path}/new"}
          class="focus-ring inline-flex items-center gap-2 rounded-lg bg-violet-600 hover:bg-violet-700 text-white px-6 py-3 text-sm font-medium transition-colors"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 20 20"
            fill="currentColor"
            class="w-5 h-5"
            aria-hidden="true"
          >
            <path d="M10.75 4.75a.75.75 0 0 0-1.5 0v4.5h-4.5a.75.75 0 0 0 0 1.5h4.5v4.5a.75.75 0 0 0 1.5 0v-4.5h4.5a.75.75 0 0 0 0-1.5h-4.5v-4.5Z" />
          </svg>
          New agent
        </.link>

        <div class="mt-6 text-xs text-zinc-500 dark:text-zinc-400">
          <%= if @workspace_state == :starting do %>
            <span class="inline-flex items-center gap-2 animate-pulse">
              <svg
                class="w-3.5 h-3.5 animate-spin"
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
                aria-hidden="true"
              >
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="4"
                >
                </circle>
                <path
                  class="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                >
                </path>
              </svg>
              Starting preview environment…
            </span>
          <% else %>
            Need to run the app?
            <button
              phx-click="boot_workspace"
              class="focus-ring underline hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors"
            >
              Start the preview environment
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Workspace overview panel for `live_action == :index` (no agent or
  # service selected). Renders the workspace label (from the Source
  # adapter — no UI-side rename), a state pill, and the appropriate
  # Start / Stop / Start All button. State-pill + button logic was
  # lifted verbatim from the previous sidebar header that this replaces.
  attr :workspace_entry, :map, required: true
  attr :workspace_state, :atom, required: true
  attr :docker_connected?, :boolean, default: true
  attr :base_path, :string, required: true

  def workspace_overview(assigns) do
    {state_label, dot_class, button} =
      case assigns.workspace_state do
        :starting -> {"Starting", "bg-blue-400 animate-pulse", :none}
        :stopping -> {"Stopping", "bg-amber-400 animate-pulse", :none}
        :started -> {"Running", "bg-emerald-500", :stop}
        :partial -> {"Partially running", "bg-amber-400", :start_all}
        :stopped -> {"Stopped", "bg-zinc-400", :start}
      end

    button = if assigns.docker_connected?, do: button, else: :none

    assigns =
      assigns
      |> assign(:state_label, state_label)
      |> assign(:dot_class, dot_class)
      |> assign(:button, button)
      |> assign(:display_name, Loopyard.Source.display_name(assigns.workspace_entry))

    ~H"""
    <div class="flex-1 overflow-y-auto p-6 md:p-10">
      <div class="max-w-2xl mx-auto">
        <div class="flex items-start justify-between gap-4 pb-6 mb-6 border-b border-zinc-200 dark:border-zinc-700/80">
          <div class="min-w-0 flex-1">
            <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100 truncate">
              {@display_name}
            </h1>
            <div class="mt-2 flex items-center gap-2">
              <div
                class={"w-2 h-2 rounded-full flex-none #{if @docker_connected?, do: @dot_class, else: "bg-amber-400 animate-pulse"}"}
                aria-hidden="true"
              >
              </div>
              <span class="text-sm text-zinc-600 dark:text-zinc-300">
                <span :if={@docker_connected?}>{@state_label}</span>
                <span :if={!@docker_connected?} class="text-amber-600 dark:text-amber-400">
                  Docker disconnected
                </span>
              </span>
            </div>
          </div>
          <div class="flex-none">
            <button
              :if={@button == :stop}
              type="button"
              phx-click="shutdown_workspace"
              aria-label="Stop workspace"
              class="focus-ring inline-flex items-center gap-2 rounded-md px-4 min-h-10 text-sm font-medium border border-zinc-200 dark:border-zinc-700 text-zinc-700 dark:text-zinc-200 hover:bg-zinc-50 dark:hover:bg-zinc-800 transition-colors"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 16 16"
                fill="currentColor"
                class="w-3.5 h-3.5"
                aria-hidden="true"
              >
                <rect x="3" y="3" width="10" height="10" rx="1.5" />
              </svg>
              Stop
            </button>
            <button
              :if={@button in [:start, :start_all]}
              type="button"
              phx-click="boot_workspace"
              aria-label="Start all services"
              class="focus-ring inline-flex items-center gap-2 rounded-md px-4 min-h-10 text-sm font-medium bg-violet-600 hover:bg-violet-700 active:bg-violet-800 text-white transition-colors"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 16 16"
                fill="currentColor"
                class="w-3.5 h-3.5"
                aria-hidden="true"
              >
                <path d="M4.5 3.5v9l7-4.5-7-4.5Z" />
              </svg>
              Start All
            </button>
          </div>
        </div>

        <p class="text-sm text-zinc-500 dark:text-zinc-400">
          Pick an agent or service from the sidebar, or <.link
            patch={"#{@base_path}/new"}
            class="text-violet-600 dark:text-violet-400 hover:underline"
          >
            launch a new agent
          </.link>.
        </p>
      </div>
    </div>
    """
  end

  def empty_state(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <div class="text-center">
        <div class="w-16 h-16 rounded-2xl bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center mx-auto mb-4">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="currentColor"
            class="w-7 h-7 text-zinc-300 dark:text-zinc-600"
          >
            <path
              fill-rule="evenodd"
              d="M4.848 2.771A49.144 49.144 0 0 1 12 2.25c2.43 0 4.817.178 7.152.52 1.978.29 3.348 2.024 3.348 3.97v6.02c0 1.946-1.37 3.68-3.348 3.97a48.901 48.901 0 0 1-3.476.383.39.39 0 0 0-.297.17l-2.755 4.133a.75.75 0 0 1-1.248 0l-2.755-4.133a.39.39 0 0 0-.297-.17 48.9 48.9 0 0 1-3.476-.384c-1.978-.29-3.348-2.024-3.348-3.97V6.741c0-1.946 1.37-3.68 3.348-3.97Z"
              clip-rule="evenodd"
            />
          </svg>
        </div>
        <p class="text-sm text-zinc-500 dark:text-zinc-400">
          Create or select an agent to start chatting
        </p>
      </div>
    </div>
    """
  end
end
