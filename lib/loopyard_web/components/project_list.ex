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
            if(@size == :full, do: "text-xl", else: "text-base"),
            "font-semibold tracking-tight text-zinc-900 dark:text-zinc-50 truncate group-hover:text-violet-600 dark:group-hover:text-violet-400 transition-colors"
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
              current={ws.id == @current_workspace_id}
              row_click={@row_click}
            />
          </div>
          <div class="hidden md:grid md:grid-cols-2 xl:grid-cols-3 gap-3">
            <.ws_card
              :for={ws <- project.workspaces}
              ws={ws}
              project_id={project.id}
              row_click={@row_click}
            />
          </div>
        </div>

        <div :if={@size != :full} class="space-y-0.5 pt-0.5">
          <.ws_row_compact
            :for={ws <- project.workspaces}
            ws={ws}
            project_id={project.id}
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
  attr :current, :boolean, default: false
  attr :row_click, :any, default: nil
  attr :size, :atom, required: true

  defp ws_row_compact(assigns) do
    assigns = assign(assigns, :headline, Birdseye.headline(assigns.ws))

    ~H"""
    <.link
      navigate={workspace_href(@project_id, @ws)}
      phx-click={@row_click}
      aria-current={@current && "true"}
      class={[
        # py-2 keeps the 40px touch target on mobile (:xs switcher sheet); the
        # desktop rail (:sm) doesn't need it and read as wasted space.
        "group/ws flex items-center gap-2.5 -mx-2 px-2 py-2 md:py-1 rounded-lg transition-colors",
        @current && "bg-violet-100 dark:bg-violet-500/15"
      ]}
    >
      <Birdseye.dot class={Birdseye.ws_dot(@ws)} size={:md} />
      <span class="min-w-0 flex-1 truncate text-sm font-medium text-zinc-900 dark:text-zinc-100 group-hover/ws:text-violet-600 dark:group-hover/ws:text-violet-400 transition-colors">
        {@ws.name}
      </span>
      <%!-- XS: ONLY the needs-you signal (picking fast). SM: the full headline
           word + the port chip in a fixed column so the rail scans straight. --%>
      <span
        :if={@headline && (@size == :sm || @headline.kind == :needs_you)}
        class={["flex-none text-xs truncate max-w-[9rem]", @headline.class]}
      >
        {@headline.text}
      </span>
      <div :if={@size == :sm} class="flex-none w-[4.25rem] flex justify-end">
        <span
          :if={ws_port(@ws)}
          class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-mono font-medium bg-emerald-500/15 text-emerald-600 dark:text-emerald-400"
        >
          :{ws_port(@ws)}
        </span>
      </div>
    </.link>
    """
  end

  # --- MD (/workspaces on small screens): two-line row --------------------------

  attr :ws, :map, required: true
  attr :project_id, :string, required: true
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
      <Birdseye.dot class={"mt-1.5 #{Birdseye.ws_dot(@ws)}"} size={:md} />
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <span class="min-w-0 flex-1 truncate text-base font-medium text-zinc-900 dark:text-zinc-100 group-hover/ws:text-violet-600 dark:group-hover/ws:text-violet-400 transition-colors">
            {@ws.name}
          </span>
          <span
            :if={ws_port(@ws)}
            class="flex-none inline-flex items-center px-1.5 py-0.5 rounded text-xs font-mono font-medium bg-emerald-500/15 text-emerald-600 dark:text-emerald-400"
          >
            :{ws_port(@ws)}
          </span>
        </div>
        <div class={["text-sm truncate", (@headline && @headline.class) || "text-zinc-500 dark:text-zinc-400"]}>
          {(@headline && @headline.text) || quiet_line(@ws)}
        </div>
      </div>
    </.link>
    """
  end

  # --- L (/workspaces on md+): the full-detail card -----------------------------

  attr :ws, :map, required: true
  attr :project_id, :string, required: true
  attr :row_click, :any, default: nil

  defp ws_card(assigns) do
    assigns = assign(assigns, :headline, Birdseye.headline(assigns.ws))

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
        <Birdseye.dot class={Birdseye.ws_dot(@ws)} size={:md} />
        <span class="min-w-0 flex-1 truncate text-base font-semibold text-zinc-900 dark:text-zinc-100">
          {@ws.name}
        </span>
        <span :if={ws_port_entry(@ws)} class="relative z-10 flex-none">
          <Birdseye.port_chip port={ws_port_entry(@ws).port} url={ws_port_entry(@ws).url} />
        </span>
      </div>
      <%!-- The story line: what it needs / what broke / what it's doing —
           or, quietly, who's here. --%>
      <div class={[
        "mt-2 text-sm truncate",
        (@headline && @headline.class) || "text-zinc-500 dark:text-zinc-400"
      ]}>
        {(@headline && agent_prefixed(@ws, @headline.text)) || quiet_line(@ws)}
      </div>
      <%!-- Footer facts: changes (when known+nonzero) · last activity. The ±N
           shows here even when a louder headline (needs-you/working) owns the
           story line — the card has room for both. --%>
      <div
        :if={card_changes(@ws) || @ws[:last_activity_at]}
        class="mt-1 text-xs text-zinc-400 dark:text-zinc-500"
      >
        <span :if={card_changes(@ws)} class="text-emerald-600/80 dark:text-emerald-400/80">
          ±{card_changes(@ws)} changes
        </span>
        <span :if={card_changes(@ws) && @ws[:last_activity_at]}> · </span>
        <span :if={@ws[:last_activity_at]}>active {time_ago(@ws.last_activity_at)}</span>
      </div>
    </div>
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

  # Quiet fallback line: who's here (the dot already says ready/asleep — no
  # status words), or that nobody is.
  defp quiet_line(%{agents: []}), do: "no agent yet"
  defp quiet_line(%{agents: [%{name: name}]}), do: name
  defp quiet_line(%{agents: agents}), do: "#{length(agents)} agents"

  defp ws_port(%{ports: [%{port: p} | _]}), do: p
  defp ws_port(_), do: nil

  # ±N for the card footer — only when known and nonzero (nil = unknown, 0 = clean).
  defp card_changes(ws) do
    case ws[:changes] do
      n when is_integer(n) and n > 0 -> n
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
