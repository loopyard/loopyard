defmodule LoopyardWeb.Components.GlobalSidebar do
  @moduledoc """
  The god-mode left rail (#55): every project → its workspaces, always
  expanded. No collapse state — projects are **sticky headers** and their
  workspaces scroll up under them (iOS grouped-list style), so you always see
  the whole map and scrolling just works. The project you're currently in
  keeps its header pinned as you scroll its workspaces.

  Fed by `Loopyard.WorkspaceTree.global/1`, kept live via the host LiveView.
  """
  use Phoenix.Component

  # Share the birdseye visual language with the home page: same status dots,
  # same aggregate logic — so moving between the rail and the home page feels like
  # one system, and the same agent never shows two different colors in two places.

  attr :tree, :list, required: true
  attr :current_workspace_id, :string, default: nil
  attr :class, :string, default: nil

  def global_sidebar(assigns) do
    ~H"""
    <nav class={["flex flex-col", @class]} aria-label="Navigation">
      <%!-- Persistent home + sound: the wordmark always returns to the root
           screen; the speaker (desktop's only always-visible header, since the
           mobile chat_header is md:hidden) toggles/opens ambient sound. Fixed
           height so nothing shifts. --%>
      <div class="flex items-center h-14 flex-none border-b border-zinc-200/70 dark:border-zinc-800">
        <%!-- Left inset matches the app header's Nav.bar pad (`px-4 md:px-5`)
             EXACTLY, so the loopyard mark sits at the same x whether you're on
             a header page (dashboard/list) or the 3-pane rail — it never jumps
             on navigation. --%>
        <.link
          navigate="/"
          aria-label="loopyard home"
          class="flex-1 min-w-0 flex items-center h-full px-4 md:px-5 text-zinc-900 dark:text-zinc-50 hover:opacity-70 transition-opacity"
        >
          <%!-- Official trefoil mark + lowercase wordmark (loopyard.ai/branding).
               Mark sized w-5 to match the breadcrumb logo exactly. --%>
          <LoopyardWeb.Components.Brand.logo mark_class="w-5 h-5 flex-none" wordmark_class="text-base tracking-tight" />
        </.link>
        <LoopyardWeb.Components.Common.sound_control id="sound-global" class="mr-1.5" />
      </div>

      <%!-- The SAME grouped list the /workspaces page and the mobile switcher use,
           so the switch gesture is identical everywhere. White scroll surface so
           the component's sticky project headers (solid bg) blend cleanly. --%>
      <%!-- StickyShadow: only THIS scrolling (compact) rail gets the pinned-header
           shadow — it turns on per header when rows start sliding under it. --%>
      <div
        id="rail-scroll"
        phx-hook="StickyShadow"
        class="flex-1 overflow-y-auto bg-white dark:bg-zinc-900 px-3 py-2"
      >
        <LoopyardWeb.Components.ProjectList.project_groups
          projects={@tree}
          current_workspace_id={@current_workspace_id}
          size={:sm}
        />
      </div>
    </nav>
    """
  end

end
