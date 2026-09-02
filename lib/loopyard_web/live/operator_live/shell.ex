defmodule LoopyardWeb.OperatorLive.Shell do
  @moduledoc """
  The Operator's page shell — ONE bar ("Loopyard › Operator", mode nav) and
  the Chat | Decisions tabs under it — shared by the operator chat
  (`/operator`, `OperatorLive`) and the decisions deck (`/operator/decisions`,
  `ReviewLive`). Both are places under the Operator: the tabs are links, so
  each tab is a URL that keeps its own state (the deck's swipe position, the
  chat's scroll) and "back" always lands where you'd expect. The bar never
  moves; only the content under it does.
  """
  use Phoenix.Component

  alias LoopyardWeb.Components.Nav
  import LoopyardWeb.Components.Breadcrumbs, only: [breadcrumbs: 1]

  attr :active, :atom, required: true, values: [:chat, :decisions]
  attr :needs_count, :integer, default: 0, doc: "decisions waiting — the tab badge"
  attr :rest, :global, doc: "id / phx-hook for the page root (the chat's ScrollBottom)"
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
        <.breadcrumbs crumbs={[{"Loopyard", "/"}, {"Operator", nil}]} />
        <:actions>
          <LoopyardWeb.Components.Common.mode_nav id="mode-operator" active={:operator} />
        </:actions>
      </Nav.bar>

      <%!-- Finger-sized tabs (py-4 + text-body ≈ 48px). The current one is a
      plain span; the other is a link — a URL can't lose its place. --%>
      <div class="app-bar-secondary flex-none flex border-b border-zinc-200 dark:border-zinc-800 text-body">
        <.tab active?={@active == :chat} navigate="/operator">Chat</.tab>
        <.tab active?={@active == :decisions} navigate="/operator/decisions">
          Decisions
          <span
            :if={@needs_count > 0}
            class="inline-flex items-center justify-center min-w-[1.25rem] h-5 px-1 rounded-full bg-violet-600 text-white text-meta font-semibold tabular-nums"
          >
            {@needs_count}
          </span>
        </.tab>
      </div>

      <div class="flex-1 min-h-0 flex">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :active?, :boolean, required: true
  attr :navigate, :string, required: true
  slot :inner_block, required: true

  defp tab(%{active?: true} = assigns) do
    ~H"""
    <span
      aria-current="page"
      class="flex-1 py-4 font-medium text-center border-b-2 -mb-px border-violet-500 text-violet-600 dark:text-violet-400 inline-flex items-center justify-center gap-1.5"
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp tab(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="focus-ring flex-1 py-4 font-medium text-center border-b-2 -mb-px border-transparent text-zinc-500 dark:text-zinc-400 inline-flex items-center justify-center gap-1.5"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
