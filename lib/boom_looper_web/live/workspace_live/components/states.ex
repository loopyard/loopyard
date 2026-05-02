defmodule BoomLooperWeb.Live.WorkspaceLive.Components.States do
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
        <p class="text-xs text-zinc-400 dark:text-zinc-500 font-mono mb-3">{@agent_id}</p>
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-4">{@status}</p>
        <details :if={@boot_log != []} class="text-left">
          <summary class="text-xs text-zinc-400 dark:text-zinc-500 cursor-pointer hover:text-zinc-600 dark:hover:text-zinc-300">
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

  def workspace_not_running(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <div class="text-center max-w-md px-4">
        <div class="w-16 h-16 rounded-2xl bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center mx-auto mb-4">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="currentColor"
            class="w-7 h-7 text-zinc-300 dark:text-zinc-600"
          >
            <path
              fill-rule="evenodd"
              d="M2.25 6a3 3 0 0 1 3-3h13.5a3 3 0 0 1 3 3v12a3 3 0 0 1-3 3H5.25a3 3 0 0 1-3-3V6Zm3.97.97a.75.75 0 0 1 1.06 0l2.25 2.25a.75.75 0 0 1 0 1.06l-2.25 2.25a.75.75 0 0 1-1.06-1.06l1.72-1.72-1.72-1.72a.75.75 0 0 1 0-1.06Zm4.28 4.28a.75.75 0 0 0 0 1.5h3a.75.75 0 0 0 0-1.5h-3Z"
              clip-rule="evenodd"
            />
          </svg>
        </div>
        <h3 class="text-lg font-semibold mb-1">{@workspace.name}</h3>
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-6">
          This workspace isn't running. Start it to bring up containers, agents, and dev services.
        </p>
        <%= if @workspace_state == :starting do %>
          <div class="inline-flex items-center gap-2 text-sm text-zinc-500 animate-pulse">
            <svg
              class="w-4 h-4 animate-spin"
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              aria-hidden="true"
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
            Starting workspace...
          </div>
        <% else %>
          <button
            phx-click="boot_workspace"
            class="focus-ring inline-flex items-center gap-2 rounded-lg bg-violet-600 hover:bg-violet-700 text-white px-6 py-3 text-sm font-medium transition-colors"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 20 20"
              fill="currentColor"
              class="w-5 h-5"
              aria-hidden="true"
            >
              <path d="M6.3 2.84A1.5 1.5 0 0 0 4 4.11v11.78a1.5 1.5 0 0 0 2.3 1.27l9.344-5.891a1.5 1.5 0 0 0 0-2.538L6.3 2.841Z" />
            </svg>
            Start workspace
          </button>
        <% end %>
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
        <p class="text-sm text-zinc-400 dark:text-zinc-500">
          Create or select an agent to start chatting
        </p>
      </div>
    </div>
    """
  end
end
