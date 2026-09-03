defmodule LoopyardWeb.Components.AppShell do
  @moduledoc """
  The app-shell page: ONE bar ("Loopyard › <page>", mode nav) over content
  that scrolls INSIDE it. The two roots that are single pages use it — the
  operator (`/operator`, your private chat into Loopyard) and notifications
  (`/notifications`, the team's inbox). Each is its own place with one bar; there
  are no tabs between them, because they are peers, not siblings under one
  thing. The bar never moves; only the content under it does.
  """
  use Phoenix.Component

  alias LoopyardWeb.Components.Nav
  import LoopyardWeb.Components.Breadcrumbs, only: [breadcrumbs: 1]

  attr :title, :string, required: true, doc: "the current crumb, e.g. \"Agents\""
  attr :mode, :atom, required: true, doc: "where we are, for the mode nav"

  attr :crumbs, :list,
    default: nil,
    doc: """
    A deeper trail than brand › title, e.g. Notifications › Past decisions.
    On a phone the back arrow goes to the crumb before the last — so a
    sub-view of a root returns to the root, not home. nil = brand › title.
    """

  attr :mode_id, :string, required: true, doc: "unique mode-nav placement id"
  attr :rest, :global, doc: "id / phx-hook for the page root (the chat's ScrollBottom)"

  slot :status,
    doc: """
    A second, quieter bar under the first: what this page is looking at right
    now. A workspace chat says this in its sidebar; the single-page shells
    have no sidebar, so a status that lives only in the transcript scrolls
    away and the page stops telling you what it's doing.
    """

  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <%!-- APP SHELL: exactly the visible viewport (h-dvh, not h-screen — on iOS
    100vh is the height with Safari's toolbar hidden, so with it showing the
    page was taller than the screen and a pull chained into the DOCUMENT and
    dragged both bars off). `data-app-shell` locks the document (app.css) so
    only the panels inside scroll. --%>
    <div
      data-app-shell
      class="h-dvh flex flex-col bg-brand-paper dark:bg-brand-ink text-zinc-900 dark:text-zinc-100 safe-area-x safe-area-top"
      {@rest}
    >
      <Nav.bar height="h-14" gap="gap-3">
        <.breadcrumbs crumbs={@crumbs || [{"Loopyard", "/"}, {@title, nil}]} />
        <:actions>
          <LoopyardWeb.Components.Common.global_nav id={@mode_id} active={@mode} />
        </:actions>
      </Nav.bar>

      <div
        :if={@status != []}
        class="app-bar-secondary flex-none flex items-center gap-2 h-10 px-4 md:px-5 border-b border-zinc-200 dark:border-zinc-700/80 text-body"
      >
        {render_slot(@status)}
      </div>

      <div class="flex-1 min-h-0 flex">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
