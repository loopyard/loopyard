defmodule LoopyardWeb.Live.WorkspaceLive.Messages.Cards.Approval do
  @moduledoc """
  The boundary-crossing **approval** card (fork / integrate /
  delete-workspace / …). Split out of
  `LoopyardWeb.Live.WorkspaceLive.Messages.Cards` — see that module for the
  card family overview. Template-only; no socket/PubSub.
  """
  use Phoenix.Component

  import LoopyardWeb.Live.WorkspaceLive.Messages.Cards.Shared, only: [embed_project: 1]

  @doc """
  The agent proposed a boundary-crossing action (fork / integrate /
  delete-workspace). An Approve/Deny card — the guardrail against an agent
  spawning or destroying workspaces unattended. Shows the resolved outcome
  (creating…, created + link, merged, denied, failed) for the whole room.
  """
  def approval_card(assigns) do
    assigns = assign(assigns, :action, assigns.msg.action)
    assigns = assign(assigns, :identity, action_identity(assigns.action))

    ~H"""
    <div class="py-3">
      <LoopyardWeb.Components.StreamCard.band tone={
        (@msg.status == :pending && :needs_you) || :neutral
      }>
        <%!-- Card anatomy: identity chip top-left (which project·workspace the
    action is about, resolved from the action's ids), label top-right,
    actions at the bottom. Without a resolvable chip the label holds
    the left edge. --%>
        <div class="flex items-center justify-between gap-3 mb-2 min-w-0">
          <LoopyardWeb.Components.Common.workspace_identity
            :if={@identity}
            project={elem(@identity, 0)}
            workspace={elem(@identity, 1)}
            state={if @msg.status == :pending, do: :needs_you, else: :done}
            size={:sm}
            class="min-w-0"
          />
          <span class={[
            "chat-meta flex items-center gap-1.5 font-semibold uppercase tracking-wide flex-none",
            (@msg.status == :pending && "text-orange-700 dark:text-orange-400/90") ||
              "text-zinc-500 dark:text-zinc-400"
          ]}>
            <svg
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 16 16"
              fill="currentColor"
              class="w-3.5 h-3.5"
            >
              <path d="M8 1.5a2 2 0 0 0-2 2v.5H4.5A1.5 1.5 0 0 0 3 5.5v.879a2.5 2.5 0 0 0 0 4.242V13.5A1.5 1.5 0 0 0 4.5 15h7a1.5 1.5 0 0 0 1.5-1.5v-2.879a2.5 2.5 0 0 0 0-4.242V5.5A1.5 1.5 0 0 0 11.5 4H10v-.5a2 2 0 0 0-2-2Z" />
            </svg>
            {cond do
              @msg.status == :pending ->
                case @action.verb do
                  :integrate -> "Merge — needs your OK"
                  :delete_workspace -> "Delete workspace — needs your OK"
                  :delete_project -> "Delete project — needs your OK"
                  :rename_workspace -> "Rename — needs your OK"
                  :rename_project -> "Rename — needs your OK"
                  :create_project -> "New project — needs your OK"
                  :peer_workspaces -> "Peer workspaces — needs your OK"
                  _ -> "Branch — needs your OK"
                end

              @msg.status in [:creating, :integrating, :deleting, :renaming] ->
                "Working…"

              @msg.status == :approved and @action.verb == :peer_workspaces ->
                "Peered"

              @msg.status == :integrated ->
                "Merged"

              @msg.status == :deleted ->
                "Deleted"

              @msg.status == :renamed ->
                "Renamed"

              @msg.status == :denied ->
                "Declined"

              @msg.status == :failed ->
                "Failed"

              true ->
                "Approved"
            end}
          </span>
        </div>

        <div
          :if={@action.verb == :peer_workspaces}
          class="chat-sub text-zinc-800 dark:text-zinc-100 mb-1"
        >
          Let
          <code class="text-sm bg-violet-200/70 dark:bg-violet-800/50 rounded-sm px-1 py-0.5">{@action[
            :workspace_name
          ] || @action[:workspace_id]}</code>
          and
          <code class="text-sm bg-violet-200/70 dark:bg-violet-800/50 rounded-sm px-1 py-0.5">{@action[
            :peer_workspace_name
          ] || @action[:peer_workspace_id]}</code>
          message each other's agents directly (both directions)
        </div>
        <div
          :if={@action.verb == :create_project}
          class="chat-sub text-zinc-800 dark:text-zinc-100 mb-1"
        >
          Create project
          <code class="text-sm bg-violet-200/70 dark:bg-violet-800/50 rounded-sm px-1 py-0.5">
            {@action.name}
          </code>
          <span class="text-zinc-400">— {@action.detail}</span>
        </div>
        <div
          :if={@action.verb == :integrate}
          class="chat-sub text-zinc-800 dark:text-zinc-100 mb-1"
        >
          Merge
          <code class="text-sm bg-violet-200/70 dark:bg-violet-800/50 rounded-sm px-1 py-0.5">
            {@action.branch}
          </code>
          →
          <code class="text-sm bg-zinc-200/70 dark:bg-zinc-700/70 rounded-sm px-1 py-0.5">main</code>
          <span class="text-zinc-400">(rebase + merge into the green main)</span>
        </div>
        <div
          :if={@action.verb == :delete_workspace}
          class="chat-sub text-zinc-800 dark:text-zinc-100 mb-1"
        >
          Delete workspace
          <code class="text-sm bg-zinc-200/70 dark:bg-zinc-700/70 rounded-sm px-1 py-0.5">
            {@action.branch}
          </code>
          <span class="text-zinc-400">— removes its env + containers (the code stays in main)</span>
        </div>
        <div
          :if={@action.verb == :delete_project}
          class="chat-sub text-zinc-800 dark:text-zinc-100 mb-1"
        >
          Delete project
          <code class="text-sm bg-zinc-200/70 dark:bg-zinc-700/70 rounded-sm px-1 py-0.5">
            {@action[:name] || @action.project_id}
          </code>
          <span class="text-zinc-400">
            — destroys ALL its workspaces (envs, containers, volumes). Irreversible.
          </span>
        </div>
        <div
          :if={@action.verb in [:rename_workspace, :rename_project]}
          class="chat-sub text-zinc-800 dark:text-zinc-100 mb-1"
        >
          Rename {if @action.verb == :rename_project, do: "project", else: "workspace"}
          <code class="text-sm bg-zinc-200/70 dark:bg-zinc-700/70 rounded-sm px-1 py-0.5">
            {@action[:old_name]}
          </code>
          →
          <code class="text-sm bg-violet-200/70 dark:bg-violet-800/50 rounded-sm px-1 py-0.5">
            {@action[:name]}
          </code>
        </div>
        <div
          :if={@action.verb == :fork}
          class="chat-sub text-zinc-800 dark:text-zinc-100 mb-1"
        >
          Fork
          <code class="text-sm bg-zinc-200/70 dark:bg-zinc-700/70 rounded-sm px-1 py-0.5">
            {@action.base}
          </code>
          → new branch
          <code class="text-sm bg-violet-200/70 dark:bg-violet-800/50 rounded-sm px-1 py-0.5">
            {@action.branch}
          </code>
          <span class="text-zinc-400">(its own isolated workspace)</span>
        </div>
        <div :if={@action[:reason]} class="chat-meta text-zinc-500 dark:text-zinc-400 mb-3">
          {@action.reason}
        </div>
        <div :if={!@action[:reason]} class="mb-3"></div>

        <%= case @msg.status do %>
          <% :pending -> %>
            <div class="flex items-center gap-2">
              <button
                type="button"
                phx-click="decide_approval"
                phx-value-approval_id={@msg.approval_id}
                phx-value-decision="approve"
                class={[
                  "focus-ring chat-sub inline-flex items-center gap-1.5 rounded-sm px-5 py-2 font-semibold text-white shadow-sm transition-colors",
                  if(@action.verb in [:delete_workspace, :delete_project],
                    do: "bg-red-600 hover:bg-red-700 shadow-red-900/20",
                    else: "bg-emerald-600 hover:bg-emerald-700 shadow-emerald-900/20"
                  )
                ]}
              >
                {cond do
                  @action.verb in [:delete_workspace, :delete_project] -> "Delete"
                  @action.verb in [:rename_workspace, :rename_project] -> "Rename"
                  true -> "Approve"
                end}
              </button>
              <button
                type="button"
                phx-click="decide_approval"
                phx-value-approval_id={@msg.approval_id}
                phx-value-decision="deny"
                class="focus-ring chat-sub inline-flex items-center rounded-sm border border-zinc-300 dark:border-zinc-600 px-5 py-2 font-medium text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
              >
                Deny
              </button>
            </div>
          <% s when s in [:creating, :integrating, :deleting, :renaming] -> %>
            <div class="chat-sub flex items-center gap-2 text-zinc-500">
              <svg
                class="w-4 h-4 animate-spin flex-none"
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
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
              <span class="font-medium">
                {cond do
                  @msg.status == :integrating ->
                    "Merging into main"

                  @msg.status == :renaming ->
                    "Renaming"

                  @msg.status == :deleting and @action.verb == :delete_project ->
                    "Deleting the project"

                  @msg.status == :deleting ->
                    "Deleting the workspace"

                  @action.verb == :create_project ->
                    "Creating the project"

                  true ->
                    "Creating the branch workspace"
                end}
              </span>
              <span :if={@msg[:detail]} class="text-zinc-400 animate-pulse truncate">
                · {@msg.detail}
              </span>
            </div>
          <% :approved -> %>
            <.link
              navigate={approved_link(@msg)}
              class="focus-ring chat-sub inline-flex items-center gap-1.5 rounded-sm bg-emerald-500/15 px-3 py-1.5 font-medium text-emerald-600 dark:text-emerald-400 hover:bg-emerald-500/25 transition-colors"
            >
              Ready — open <code class="text-sm">{@action[:name] || @action[:branch]}</code> →
            </.link>
          <% :integrated -> %>
            <span class="chat-sub inline-flex items-center gap-1.5 rounded-sm bg-emerald-500/15 px-3 py-1.5 font-medium text-emerald-600 dark:text-emerald-400">
              Merged <code class="text-sm">{@action.branch}</code> → main ✓
            </span>
          <% :deleted -> %>
            <span class="chat-sub inline-flex items-center gap-1.5 rounded-sm bg-zinc-500/15 px-3 py-1.5 font-medium text-zinc-600 dark:text-zinc-300">
              Deleted
              <code class="text-sm">{@action[:name] || @action[:branch] || @action[:workspace_id]}</code>
              ✓
            </span>
          <% :renamed -> %>
            <span class="chat-sub inline-flex items-center gap-1.5 rounded-sm bg-emerald-500/15 px-3 py-1.5 font-medium text-emerald-600 dark:text-emerald-400">
              Renamed → <code class="text-sm">{@action[:name]}</code> ✓
            </span>
          <% :denied -> %>
            <span class="chat-meta text-zinc-500 dark:text-zinc-400">Declined.</span>
          <% :failed -> %>
            <span class="chat-sub text-red-500">
              {case @action.verb do
                :integrate -> "Merge failed"
                :create_project -> "Couldn't create the project"
                :delete_workspace -> "Couldn't delete the workspace"
                :delete_project -> "Couldn't delete the project"
                _ -> "Couldn't create the branch"
              end}: {@msg[:error]}
            </span>
          <% _ -> %>
            <span></span>
        <% end %>
      </LoopyardWeb.Components.StreamCard.band>
    </div>
    """
  end

  # The approval's subject as {project_name, workspace_name} for the identity
  # chip, resolved from the action's ids (project name via registry, workspace
  # name likewise; the branch stands in for a not-yet-created workspace on fork).
  # nil when nothing is resolvable — the card renders label-only.
  defp action_identity(action) do
    case embed_project(%{project_id: action[:project_id]}) do
      proj when is_binary(proj) -> {proj, action_workspace_name(action)}
      _ -> nil
    end
  end

  defp action_workspace_name(%{workspace_id: wid} = action) when is_binary(wid) do
    case Loopyard.WorkspaceRegistry.get_workspace(wid) do
      %{name: n} when is_binary(n) -> n
      _ -> action[:branch]
    end
  rescue
    _ -> action[:branch]
  catch
    _, _ -> action[:branch]
  end

  defp action_workspace_name(action), do: action[:branch]

  # Where "Open" lands after a fork is approved: straight on the branch's agent
  # when it was provisioned (it always is now), else the workspace.
  defp approved_link(msg) do
    base = "/projects/#{msg[:project_id]}/workspaces/#{msg[:workspace_id]}"
    if msg[:agent_id], do: "#{base}/agents/#{msg[:agent_id]}", else: base
  end
end
