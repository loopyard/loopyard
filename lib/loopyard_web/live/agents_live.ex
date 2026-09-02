defmodule LoopyardWeb.AgentsLive do
  @moduledoc """
  `/agents` — every agent, flat, whatever its scope: "oh look, there's a
  bunch of agents." One place for the status of all of them; tap in to
  follow along. System agents first (the operator and its peers), then
  each project · workspace's. Launch a new SYSTEM agent from here
  (`/agents/new`); workspace agents are launched in their workspace, since
  they need one chosen.

  Live: re-reads on any agent status/boot/removal event and on inbox
  changes (one ETS read; no per-row polling).
  """
  use LoopyardWeb, :live_view

  alias Loopyard.{Agents, Events}
  alias Loopyard.Agents.Template
  alias LoopyardWeb.AgentsLive.Row
  alias LoopyardWeb.Components.AppShell

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.ChatAgent.subscribe()
      Events.Notifications.subscribe()
    end

    {:ok,
     socket
     |> assign(:templates, Enum.filter(Template.all(), &Template.system?/1))
     |> assign(:form, to_form(%{"name" => "", "template_id" => "system"}))
     |> load()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp load(socket) do
    waiting = Loopyard.Notifications.open(:decisions) |> MapSet.new(& &1.agent_id)
    rows = Agents.summaries() |> Row.rows(waiting)

    groups =
      rows
      |> Enum.group_by(& &1.group)
      |> Enum.sort_by(fn {group, _} -> if group == "System", do: {0, ""}, else: {1, group} end)

    assign(socket, rows: rows, groups: groups, working: Row.working_count(rows))
  end

  @impl true
  def handle_info(%{__struct__: mod}, socket) when is_atom(mod) do
    if mod in Events.ChatAgent.events() or mod in Events.Notifications.events(),
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("create_agent", %{"name" => name, "template_id" => template_id}, socket) do
    name = String.trim(name)
    opts = [template_id: template_id] ++ if(name != "", do: [name: name], else: [])

    case Agents.create_system(opts) do
      {:ok, id} ->
        {:noreply, push_navigate(socket, to: "/agents/#{id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't create the agent: #{inspect(reason)}")}
    end
  end

  def handle_event(_evt, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <AppShell.shell title="Agents" mode={:agents} mode_id="mode-agents">
      <div class="flex-1 min-w-0 min-h-0 overflow-y-auto">
        <div class="mx-auto w-full max-w-3xl px-4 md:px-6 py-4">
          <%!-- The one line that says how the fleet is, then the rows. --%>
          <div class="flex items-center gap-3 mb-2">
            <p class="text-body text-zinc-500 dark:text-zinc-400">
              {length(@rows)} {plural(length(@rows), "agent")} · {@working} working
            </p>
            <.link
              :if={@live_action != :new}
              patch="/agents/new"
              class="ml-auto text-body font-medium inline-flex items-center min-h-11 md:min-h-0 text-violet-600 dark:text-violet-400 hover:underline"
            >
              + New system agent
            </.link>
          </div>

          <%!-- New system agent: a name and a template. Stamped from the
          template's preset; boots via the saga; you land on it booting. --%>
          <.form
            :if={@live_action == :new}
            id="new-agent-form"
            for={@form}
            phx-submit="create_agent"
            class="mb-6 p-4 border border-zinc-200 dark:border-zinc-800 flex flex-col gap-3"
          >
            <label class="text-meta font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
              New system agent
            </label>
            <input
              type="text"
              name="name"
              placeholder="Name (optional — defaults to the template's)"
              class="focus-ring text-body min-h-11 px-3 rounded-sm bg-white dark:bg-zinc-900 border border-zinc-300 dark:border-zinc-700"
            />
            <select
              name="template_id"
              class="focus-ring text-body min-h-11 px-3 rounded-sm bg-white dark:bg-zinc-900 border border-zinc-300 dark:border-zinc-700"
            >
              <option :for={t <- @templates} value={t.id}>{t.name} — {t.description}</option>
            </select>
            <div class="flex items-center gap-2">
              <button
                type="submit"
                class={
                  LoopyardWeb.Components.StreamCard.action_class(variant: :primary, tone: :confirm)
                }
              >
                Create
              </button>
              <.link patch="/agents" class={LoopyardWeb.Components.StreamCard.action_class()}>
                Cancel
              </.link>
            </div>
          </.form>

          <p :if={@rows == []} class="py-12 text-center text-body text-zinc-400 dark:text-zinc-500">
            No agents yet.
          </p>

          <section :for={{group, rows} <- @groups} class="pt-4">
            <div class="section-label px-2 pb-1">{group}</div>
            <div class="space-y-px">
              <Row.agent_row :for={row <- rows} row={row} />
            </div>
          </section>
        </div>
      </div>
    </AppShell.shell>
    """
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
