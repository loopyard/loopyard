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
      <%!-- No brand/mode head here any more: the chat page now renders ONE
    full-width bar above both rails (workspace_live.ex), so the wordmark
    and mode icons sit at the same place as every other surface instead of
    being nested in this column. --%>
      <%!-- The SAME grouped list the /workspaces page and the mobile switcher use,
    so the switch gesture is identical everywhere. A subtly TINTED surface
    (zinc-50, not pure white) so the rail reads as distinct from the white
    chat content beside it; the component's sticky project headers match. --%>
      <%!-- StickyShadow: only THIS scrolling (compact) rail gets the pinned-header
    shadow — it turns on per header when rows start sliding under it. --%>
      <%!-- px-4 md:px-5 matches the header's logo/speaker pad EXACTLY — project
    names, workspace rows, and the wordmark share one left gutter (rows'
    -mx-2 hover bg bleeds into it without moving the text edge). --%>
      <div
        id="rail-scroll"
        phx-hook="StickyShadow"
        class="flex-1 overflow-y-auto bg-brand-paper-shade dark:bg-brand-ink px-4 md:px-5 py-2"
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
