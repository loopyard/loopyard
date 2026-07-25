defmodule LoopyardWeb.Components.ProjectList do
  @moduledoc """
  The ONE grouped project → workspace overview, rendered at three sizes so the
  gesture is learned once and the SAME status model shows everywhere:

    * `size={:xs}` — the mobile switcher sheet: dot + name, needs-you badge
      only. Picking fast; no port/status noise.
    * `size={:sm}` — the desktop rail: one aligned line per workspace —
      dot + name … headline word + port chip.
    * `size={:full}` — /workspaces: responsive. Small screens get two-line
      rows; md+ gets a GRID OF CARDS per project with the full story (agent +
      activity, port, last active), needs-you/broken tinting the card.

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
  @working_statuses [:thinking, :compacting, :booting, :backoff, :rate_limited]

  @doc """
  Renders the grouped overview.

    * `projects` — `WorkspaceTree.global` list.
    * `current_workspace_id` — highlight this workspace's row (switcher/rail).
    * `row_click` — optional `JS` run when a row is tapped (e.g. close sheet).
    * `size` — `:xs` | `:sm` | `:full` (see moduledoc).
  """
  attr :projects, :list, required: true
  attr :current_workspace_id, :string, default: nil
  attr :row_click, :any, default: nil
  attr :size, :atom, default: :full, values: [:xs, :sm, :full]

  def project_groups(assigns) do
    ~H"""
    <div class={if @size == :full, do: "space-y-9", else: "space-y-6"}>
      <section :for={project <- @projects}>
        <%!-- Project header: just the name (→ the project page, where "New
             workspace" lives). STICKY so it pins while its workspaces scroll;
             opaque bg covers rows sliding under; shadow only when stuck. --%>
        <.link
          navigate={"/projects/#{project.id}"}
          phx-click={@row_click}
          data-sticky-header
          class={[
            "group sticky top-0 z-10 block pt-1 pb-1 transition-shadow data-[stuck]:shadow-[0_5px_6px_-6px_rgba(0,0,0,0.28)]",
            # Match the container: the compact rail sits on a tinted (zinc-50)
            # surface; /workspaces + the switcher sheet sit on white.
            if(@size == :sm, do: "bg-zinc-50", else: "bg-white"),
            "dark:bg-zinc-900"
          ]}
        >
          <h2 class={[
            # The rail/switcher is AMBIENT navigation, not the star — so the
            # project header recedes to a quiet, muted section label (the chat is
            # the focus). Only /workspaces (:full) keeps a prominent heading.
            if(@size == :full,
              do: "text-xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50",
              else:
                "text-[11px] font-semibold uppercase tracking-wider text-zinc-400 dark:text-zinc-500"
            ),
            "truncate group-hover:text-violet-600 dark:group-hover:text-violet-400 transition-colors"
          ]}>
            {project.name}
          </h2>
        </.link>

        <%!-- :full renders two-line rows on small screens and the card grid on
             md+ — one render, responsive, no UA sniffing. :xs/:sm are single
             compact rows. --%>
        <div :if={@size == :full} class="pt-1">
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

        <div :if={@size != :full} class="space-y-0.5 pt-0.5">
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

        <div
          :if={project.workspaces == []}
          class="px-2 py-2 text-sm text-zinc-500 dark:text-zinc-400 italic"
        >
          no workspaces
        </div>
      </section>

      <div :if={@projects == []} class="text-sm text-zinc-400 py-8 text-center">
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
      # py-2 keeps the 40px touch target on mobile (:xs switcher sheet); the
      # desktop rail (:sm) doesn't need it and read as wasted space.
      "group/ws relative flex items-center gap-2.5 -mx-2 px-2 py-2 md:py-1 rounded-lg transition-colors",
      @current && "bg-violet-100 dark:bg-violet-500/15"
    ]}>
      <.link
        navigate={workspace_href(@project_id, @ws)}
        phx-click={@row_click}
        aria-current={@current && "true"}
        aria-label={"Open workspace #{@ws.name}"}
        class="absolute inset-0 rounded-lg focus-ring"
      >
      </.link>
      <%!-- The project is the STICKY HEADER right above, so the row shows just the
           workspace (● name) — no redundant project — and mutes it in the rail
           (:sm) so the nav recedes behind the chat. --%>
      <LoopyardWeb.Components.Common.workspace_identity
        project={@ws.name}
        workspace={nil}
        state={ws_state(@ws)}
        size={:sm}
        muted={@size == :sm}
        class="min-w-0 flex-1"
      />
      <%!-- The rail carries only the SIGNAL words (needs-you / broken / …), never
           the loud green/red git line-stats — those are noise in a nav rail and
           live in the right sidebar's Changes row instead. XS shows only the
           needs-you signal (picking fast); SM shows any signal word. --%>
      <span
        :if={@headline && @headline.kind != :changed && (@size == :sm || @headline.kind == :needs_you)}
        class="relative flex-none text-xs truncate max-w-[9rem]"
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
        "group/ws flex items-start gap-2.5 -mx-2 px-2 py-2 rounded-lg transition-colors",
        @current && "bg-violet-100 dark:bg-violet-500/15"
      ]}
    >
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <LoopyardWeb.Components.Common.workspace_identity
            project={@project_name}
            workspace={@ws.name}
            state={ws_state(@ws)}
            size={:md}
            class="min-w-0 flex-1"
          />
          <span
            :if={ws_port(@ws)}
            class="flex-none inline-flex items-center px-1.5 py-0.5 rounded text-xs font-mono font-medium bg-emerald-500/15 text-emerald-600 dark:text-emerald-400"
          >
            :{ws_port(@ws)}
          </span>
        </div>
        <div class={[
          "text-sm truncate",
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
    <div class={[
      "relative rounded-xl border p-4 transition-colors",
      card_tint(@headline)
    ]}>
      <%!-- Stretched link covers the card (→ the agent chat) WITHOUT nesting
           anchors; the port chip sits above it (z-10) as its own link. --%>
      <.link
        navigate={workspace_href(@project_id, @ws)}
        phx-click={@row_click}
        class="absolute inset-0 rounded-xl focus-ring"
        aria-label={"Open workspace #{@ws.name}"}
      >
      </.link>
      <div class="flex items-center gap-2">
        <LoopyardWeb.Components.Common.workspace_identity
          project={@project_name}
          workspace={@ws.name}
          state={ws_state(@ws)}
          size={:md}
          class="min-w-0 flex-1"
        />
        <span :if={ws_port_entry(@ws)} class="relative z-10 flex-none">
          <Birdseye.port_chip port={ws_port_entry(@ws).port} url={ws_port_entry(@ws).url} />
        </span>
      </div>
      <%!-- The story line: what it needs / what broke / what it's doing — or,
           quietly, who's here. A `:changed` headline is NOT a story (it's a
           footer fact), so on the card it collapses to the quiet who's-here line;
           ±N shows once, in the footer. --%>
      <div class={[
        "mt-2 text-sm truncate",
        card_story_class(@headline) || "text-zinc-500 dark:text-zinc-400"
      ]}>
        {card_story_text(@headline, @ws)}
      </div>
      <%!-- Footer facts: last activity (the STEADY anchor — always present) then
           changes to its RIGHT (conditional: only when known + nonzero). This is
           the ONLY place ±N shows; the story line never repeats it. --%>
      <div
        :if={@ws[:last_activity_at] || @changes}
        class="mt-1 text-xs text-zinc-400 dark:text-zinc-500"
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
  defp ws_state(ws) do
    cond do
      ws[:needs_you] ->
        :needs_you

      ws[:broken] ->
        :broken

      true ->
        statuses = Enum.map(ws[:agents] || [], &Map.get(&1, :status))

        cond do
          Enum.any?(statuses, &(&1 == :auth_expired)) -> :broken
          Enum.any?(statuses, &(&1 in @working_statuses)) -> :working
          Enum.any?(statuses, &(&1 == :idle)) -> :done
          true -> :asleep
        end
    end
  end

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
