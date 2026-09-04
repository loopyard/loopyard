defmodule LoopyardWeb.Components.ProjectList do
  @moduledoc """
  The ONE grouped project → workspace overview.

  * `size={:full}` — /workspaces AND the mobile switcher sheet: responsive.
  Small screens get two-line rows; md+ gets a GRID OF CARDS per project with
  the full story (agent + activity, port, last active), needs-you/broken
  tinting the card.
  * `size={:sm}` — the desktop rail: one aligned line per workspace —
  dot + name … headline word + port chip. A genuinely different affordance
  (a 288px column beside the content), not a smaller copy of the list.

  There used to be a third size for the mobile switcher, and it was a mistake:
  the switcher shows the SAME list as /workspaces, one screen apart, so every
  time either was tuned they drifted — different row heights, different type,
  a different left edge. One rendering means they cannot.

  All sizes derive from `Birdseye.ws_dot/1` + `Birdseye.headline/1` — the
  priority-ordered status model (needs-you > broken > working > quiet). The dot
  carries the STATE; the text always carries NEW information (what it wants,
  what broke, what it's doing) — never a redundant color-word like "idle".
  Data is `Loopyard.WorkspaceTree.global/1`.
  """
  use Phoenix.Component

  alias LoopyardWeb.Components.Birdseye

  import LoopyardWeb.Live.WorkspaceLive.Components.Formatters, only: [time_ago: 1]

  # The raw agent statuses that mean "a turn is live" — mirrors Birdseye's
  # @working so the canonical workspace_identity light agrees with the ws_dot.

  @doc """
  Renders the grouped overview.

  * `projects` — `WorkspaceTree.global` list.
  * `current_workspace_id` — highlight this workspace's row (switcher/rail).
  * `row_click` — optional `JS` run when a row is tapped (e.g. close sheet).
  * `size` — `:sm` | `:full` (see moduledoc).
  """
  attr :projects, :list, required: true
  attr :current_workspace_id, :string, default: nil
  attr :row_click, :any, default: nil
  attr :size, :atom, default: :full, values: [:sm, :full]

  def project_groups(%{size: :full} = assigns) do
    ~H"""
    <div class="space-y-9">
      <section :for={project <- @projects}>
        <%!-- Project header (→ the project page, where "New workspace" lives).
    STICKY so it pins while its workspaces scroll; opaque bg covers rows
    sliding under; shadow only when stuck. --%>
        <.link
          navigate={"/projects/#{project.id}"}
          phx-click={@row_click}
          data-sticky-header
          class="group sticky top-0 z-10 block pt-2.5 pb-2.5 md:pt-1 md:pb-1 bg-brand-paper dark:bg-brand-ink transition-shadow data-[stuck]:shadow-stuck"
        >
          <h2 class="text-title font-semibold tracking-tight text-zinc-900 dark:text-zinc-50 truncate group-hover:text-violet-600 dark:group-hover:text-violet-400 transition-colors">
            {project.name}
          </h2>
        </.link>

        <%!-- Two-line rows on small screens, the card grid on md+ — one render,
    responsive, no UA sniffing. --%>
        <div class="pt-1">
          <div class="md:hidden space-y-0.5">
            <.ws_row_md
              :for={ws <- project.workspaces}
              ws={ws}
              project_id={project.id}
              project_name={project.name}
              current={ws.id == @current_workspace_id}
              row_click={@row_click}
            />
          </div>
          <div class="hidden md:grid md:grid-cols-2 xl:grid-cols-3 gap-3">
            <.ws_card
              :for={ws <- project.workspaces}
              ws={ws}
              project_id={project.id}
              project_name={project.name}
              row_click={@row_click}
            />
          </div>
        </div>

        <div
          :if={project.workspaces == []}
          class="px-2 py-2 text-body text-zinc-500 dark:text-zinc-400 italic"
        >
          no workspaces
        </div>
      </section>

      <div :if={@projects == []} class="text-body text-zinc-400 py-8 text-center">
        No projects yet.
      </div>
    </div>
    """
  end

  # Compact rail (:sm): projects are GROUPS. The project name is
  # the group heading — WHITE, readable (a real heading, not a muted label) —
  # and its branches sit indented below it, each a status light + branch name.
  # Generous space BETWEEN projects so the groups read as distinct.
  def project_groups(assigns) do
    ~H"""
    <div class="space-y-4">
      <section :for={project <- @projects}>
        <%!-- The group heading = the project, as white readable text. Sticky so
    it pins while its branches scroll; opaque bg (matches the rail)
    covers rows sliding under; shadow only when stuck. --%>
        <.link
          navigate={"/projects/#{project.id}"}
          phx-click={@row_click}
          data-sticky-header
          class={[
            "group sticky top-0 z-10 flex items-center bg-brand-paper-shade dark:bg-brand-ink transition-shadow data-[stuck]:shadow-stuck",
            "pb-1"
          ]}
        >
          <h2 class={[
            "font-semibold tracking-tight text-zinc-900 dark:text-zinc-50 truncate group-hover:text-violet-600 dark:group-hover:text-violet-400 transition-colors",
            "text-body"
          ]}>
            {project.name}
          </h2>
        </.link>

        <%!-- Branches under the project. NOT indented: the heading sat at x=8
    and the rows at x=12, which is too small to read as hierarchy — it
    just looked like a broken gutter (ui-rhythm Rule 3: don't indent
    unless the indent encodes hierarchy the reader needs). The status
    light is the anchor that distinguishes a branch from its project, and
    every row's dot now shares the heading's left edge. --%>
        <div class="space-y-0.5">
          <.ws_row_compact
            :for={ws <- project.workspaces}
            ws={ws}
            project_id={project.id}
            project_name={project.name}
            current={ws.id == @current_workspace_id}
            row_click={@row_click}
            size={@size}
          />
        </div>
      </section>

      <div :if={@projects == []} class="text-body text-zinc-400 py-8 text-center">
        No projects yet.
      </div>
    </div>
    """
  end

  # --- XS (switcher) + SM (rail): one compact line ------------------------------

  attr :ws, :map, required: true
  attr :project_id, :string, required: true
  attr :project_name, :string, required: true
  attr :current, :boolean, default: false
  attr :row_click, :any, default: nil
  attr :size, :atom, required: true

  defp ws_row_compact(assigns) do
    assigns = assign(assigns, :headline, Birdseye.headline(assigns.ws))

    ~H"""
    <%!-- Stretched-link row: the whole row navigates to the workspace via an
    absolute overlay link, so the port chip can sit ABOVE it (z-10) as its
    OWN link — one tap opens the running dev server in a new tab without
    first opening the workspace and hunting for it. --%>
    <div class={[
      "group/ws relative flex items-center gap-2.5 -mx-2 px-2 rounded-sm transition-colors",
      "py-1",
      @current && "bg-violet-100 dark:bg-violet-500/15"
    ]}>
      <.link
        navigate={workspace_href(@project_id, @ws)}
        phx-click={@row_click}
        aria-current={@current && "true"}
        aria-label={"Open workspace #{@ws.name}"}
        class="absolute inset-0 rounded-sm focus-ring"
      ></.link>
      <%!-- Indented BRANCH row: the project (white heading) is right above, so
    this shows just the branch — status light on the left, branch name to
    its right — quietly (muted) so the project heading leads. --%>
      <%!-- :md at BOTH sizes so this rail reads at the same scale as the right
    sidebar's nav rows (text-body). It was :sm here, which maps to the tiny
    text-meta token — the left rail ended up noticeably smaller and harder
    to read than the identical list on the right. Not muted for the same
    reason: legible first, recessive second. --%>
      <LoopyardWeb.Components.Common.workspace_identity
        project={@ws.name}
        state={ws_state(@ws)}
        class="min-w-0 flex-1"
      />
      <%!-- The rail carries only the SIGNAL words (needs-you / broken / …), never
    the loud green/red git line-stats — those are noise in a nav rail and
    live in the right sidebar's Changes row instead. XS shows only the
    needs-you signal (picking fast); SM shows any signal word. --%>
      <span
        :if={
          @headline && @headline.kind != :changed && (@size == :sm || @headline.kind == :needs_you)
        }
        class="relative flex-none text-meta truncate max-w-[9rem]"
      >
        <span class={@headline.class}>{@headline.text}</span>
      </span>
      <div :if={@size == :sm} class="relative z-10 flex-none w-[4.25rem] flex justify-end">
        <Birdseye.port_chip
          :if={ws_port_entry(@ws) && ws_port_entry(@ws).url}
          port={ws_port_entry(@ws).port}
          url={ws_port_entry(@ws).url}
        />
      </div>
    </div>
    """
  end

  # --- MD (/workspaces on small screens): two-line row --------------------------

  attr :ws, :map, required: true
  attr :project_id, :string, required: true
  attr :project_name, :string, required: true
  attr :current, :boolean, default: false
  attr :row_click, :any, default: nil

  defp ws_row_md(assigns) do
    assigns = assign(assigns, :headline, Birdseye.headline(assigns.ws))

    ~H"""
    <.link
      navigate={workspace_href(@project_id, @ws)}
      phx-click={@row_click}
      aria-current={@current && "true"}
      class={[
        "group/ws flex items-start gap-2.5 -mx-2 px-2 py-2 rounded-sm transition-colors",
        @current && "bg-violet-100 dark:bg-violet-500/15"
      ]}
    >
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <%!-- The project HEADER right above owns the project name — the row
    shows just the branch, so the header (big) → branch (small) reads
    as real hierarchy instead of "Loopyard / Loopyard · main". --%>
          <LoopyardWeb.Components.Common.workspace_identity
            project={@ws.name}
            state={ws_state(@ws)}
            class="min-w-0 flex-1"
          />
          <span
            :if={ws_port(@ws)}
            class="flex-none inline-flex items-center px-1.5 py-0.5 rounded-sm text-meta font-mono font-medium bg-emerald-500/15 text-emerald-600 dark:text-emerald-400"
          >
            :{ws_port(@ws)}
          </span>
        </div>
        <div class={[
          "text-body truncate",
          (@headline && @headline.kind != :changed && @headline.class) ||
            "text-zinc-500 dark:text-zinc-400"
        ]}>
          <.change_stat
            :if={@headline && @headline.kind == :changed}
            added={@headline.added}
            removed={@headline.removed}
          />
          <span :if={!(@headline && @headline.kind == :changed)}>
            {(@headline && @headline.text) || quiet_line(@ws)}
          </span>
        </div>
      </div>
    </.link>
    """
  end

  # --- L (/workspaces on md+): the full-detail card -----------------------------

  attr :ws, :map, required: true
  attr :project_id, :string, required: true
  attr :project_name, :string, required: true
  attr :row_click, :any, default: nil

  defp ws_card(assigns) do
    assigns =
      assigns
      |> assign(:headline, Birdseye.headline(assigns.ws))
      |> assign(:changes, card_changes(assigns.ws))

    ~H"""
    <%!-- Weight matched to the dashboard cards: same padding and a real
         min-height, so a workspace reads as a CARD rather than a bordered
         line of text. The grid was previously one thin box floating in an
         empty page. --%>
    <div class={[
      "relative border p-5 md:p-6 min-h-[9rem] flex flex-col transition-colors",
      card_tint(@headline)
    ]}>
      <%!-- Stretched link covers the card (→ the agent chat) WITHOUT nesting
    anchors; the port chip sits above it (z-10) as its own link. --%>
      <.link
        navigate={workspace_href(@project_id, @ws)}
        phx-click={@row_click}
        class="absolute inset-0  focus-ring"
        aria-label={"Open workspace #{@ws.name}"}
      ></.link>
      <div class="flex items-center gap-2">
        <%!-- The project header above the grid owns the project name — the card
    leads with its branch (see ws_row_md). --%>
        <LoopyardWeb.Components.Common.workspace_identity
          project={@ws.name}
          state={ws_state(@ws)}
          class="min-w-0"
        />
        <%!-- Named only when it departs from rest — the shared component owns
             that rule, so "Ready" can't creep back in beside a green dot. --%>
        <LoopyardWeb.Components.Common.status_label
          state={ws_state(@ws)}
          class="hidden sm:inline text-meta text-body"
        />
        <div class="flex-1"></div>
        <span :if={ws_port_entry(@ws)} class="relative z-10 flex-none">
          <Birdseye.port_chip port={ws_port_entry(@ws).port} url={ws_port_entry(@ws).url} />
        </span>
      </div>
      <%!-- The story line: what it needs / what broke / what it's doing — or,
    quietly, who's here. A `:changed` headline is NOT a story (it's a
    footer fact), so on the card it collapses to the quiet who's-here line;
    ±N shows once, in the footer. --%>
      <div class={[
        "mt-2 text-body truncate",
        card_story_class(@headline) || "text-zinc-500 dark:text-zinc-400"
      ]}>
        {card_story_text(@headline, @ws)}
      </div>
      <%!-- Footer facts: last activity (the STEADY anchor — always present) then
    changes to its RIGHT (conditional: only when known + nonzero). This is
    the ONLY place ±N shows; the story line never repeats it. Pushed to the
    bottom (mt-auto) so every card in the row shares one baseline. --%>
      <div class="mt-auto"></div>
      <div
        :if={@ws[:last_activity_at] || @changes}
        class="mt-1 text-meta text-body text-zinc-400 dark:text-zinc-500"
      >
        <span :if={@ws[:last_activity_at]}>Active {time_ago(@ws.last_activity_at)}</span>
        <span :if={@ws[:last_activity_at] && @changes}> · </span>
        <.change_stat :if={@changes} added={@changes.added} removed={@changes.removed} />
      </div>
    </div>
    """
  end

  # The ONE git-stat renderer — +additions green, −deletions red — used by the
  # card footer AND the compact/rail rows, so the colour split is identical
  # everywhere (a compact row's "−11" is red too, not a single-colour headline).
  attr :added, :integer, required: true
  attr :removed, :integer, required: true

  defp change_stat(assigns) do
    ~H"""
    <span class="tabular-nums font-medium"><span
      :if={@added > 0}
      class="text-emerald-600 dark:text-emerald-400"
    >+{@added}</span><span :if={@added > 0 && @removed > 0} class="inline-block w-1"></span><span
      :if={@removed > 0}
      class="text-red-500 dark:text-red-400"
    >−{@removed}</span></span>
    """
  end

  # needs-you/broken tint the whole card edge; everything else stays quiet.
  defp card_tint(%{kind: :needs_you}),
    do: "border-amber-300 dark:border-amber-500/40 bg-amber-50/40 dark:bg-amber-500/5"

  defp card_tint(%{kind: :broken}),
    do: "border-red-300 dark:border-red-500/40 bg-red-50/40 dark:bg-red-500/5"

  defp card_tint(_),
    do:
      "border-zinc-200 dark:border-zinc-800 hover:border-violet-300 dark:hover:border-violet-500/40"

  # "Claude · editing files" — the card has room for WHO before the what.
  defp agent_prefixed(%{agents: [%{name: name} | _]}, text) when is_binary(name),
    do: "#{name} · #{text}"

  defp agent_prefixed(_, text), do: text

  # Card story line: a `:changed` headline is a footer fact, not a story, so it
  # collapses to the quiet who's-here line (±N shows only in the footer). Real
  # stories (needs-you/broken/working) show with their colour.
  defp card_story_text(%{kind: :changed}, ws), do: quiet_line(ws)
  defp card_story_text(%{text: text}, ws), do: agent_prefixed(ws, text)
  defp card_story_text(_, ws), do: quiet_line(ws)

  defp card_story_class(%{kind: :changed}), do: nil
  defp card_story_class(%{class: class}), do: class
  defp card_story_class(_), do: nil

  # Quiet fallback line: who's here (the dot already says ready/asleep — no
  # status words), or that nobody is.
  defp quiet_line(%{agents: []}), do: "no agent yet"
  defp quiet_line(%{agents: [%{name: name}]}), do: name
  defp quiet_line(%{agents: agents}), do: "#{length(agents)} agents"

  defp ws_port(%{ports: [%{port: p} | _]}), do: p
  defp ws_port(_), do: nil

  # Map a workspace onto the ONE canonical workspace_identity light — same
  # priority order as Birdseye.ws_dot/1 (needs-you > broken > working > ready >
  # asleep) so the badge's light and the tree's dot can never disagree.
  # The ONE derivation lives in Common (beside state_light/1 and status_word/1)
  # so the dot colour, the word, and the state can't drift apart.
  defp ws_state(ws), do: LoopyardWeb.Components.Common.workspace_state(ws)

  # Line +/- for the card footer — %{added, removed}, only when known and nonzero
  # (nil = unknown / no running container, or clean = 0 add + 0 remove).
  defp card_changes(ws) do
    case ws[:changes] do
      %{added: a, removed: r} when a + r > 0 -> %{added: a, removed: r}
      _ -> nil
    end
  end

  defp ws_port_entry(%{ports: [entry | _]}), do: entry
  defp ws_port_entry(_), do: nil

  # Link straight to an agent when the workspace has one — one navigation lands
  # on the chat. Empty workspace → its :index (which spawns an agent).
  defp workspace_href(project_id, %{agents: [agent | _]} = ws) when is_map(agent) do
    "/projects/#{project_id}/workspaces/#{ws.id}/agents/#{agent.id}"
  end

  defp workspace_href(project_id, ws), do: "/projects/#{project_id}/workspaces/#{ws.id}"
end
