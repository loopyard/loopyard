defmodule LoopyardWeb.DashboardLive do
  @moduledoc """
  The homepage (`/`): a read-only status dashboard. One card per area of the
  system — Workspaces, Remote, System, Operated — each showing a live status
  summary and navigating into that area. This is what the old mobile overflow
  menu became.

  Live-updating two ways: it subscribes to global agent Activity (so the
  Workspaces card reacts the instant an agent changes state) and runs a short
  refresh tick for the areas that have no PubSub of their own (remote exposure,
  system health, operated-as). Everything routes through `refresh/1`.
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  import LoopyardWeb.Components.Dashboard

  @refresh_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        Loopyard.Events.Activity.subscribe_global()
        Process.send_after(self(), :refresh, @refresh_ms)
        subscribe_iex(socket)
      else
        assign(socket, :iex_session, %{level: nil})
      end

    host =
      case socket.host_uri do
        %URI{host: h} when is_binary(h) and h != "" -> h
        _ -> "localhost"
      end

    {:ok, socket |> assign(:host, host) |> refresh()}
  end

  # A turn finished / started / an agent errored → the Workspaces card changes.
  @impl true
  def handle_info(%Loopyard.Events.Activity.Event{kind: :status}, socket),
    do: {:noreply, refresh(socket)}

  def handle_info(%Loopyard.Events.Activity.Event{}, socket), do: {:noreply, socket}

  # The heartbeat: refresh remote / system / operated (no PubSub) and reschedule.
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, refresh(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Recompute every card's snapshot. Each getter is crash-safe so one wedged
  # subsystem can't blank the whole dashboard.
  defp refresh(socket) do
    socket
    |> assign(:tree, safe(fn -> Loopyard.WorkspaceTree.global(socket.assigns.host) end, []))
    |> assign(:health, safe(&Loopyard.Health.severity/0, :unknown))
    |> assign(:remote_exposed, safe(&Loopyard.HostExposer.exposed?/0, false))
    |> assign(:operator, safe(&Loopyard.Workstation.current/0, "—"))
    |> assign(:operator_count, safe(fn -> length(Loopyard.Workstation.list()) end, 1))
  end

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :ws, workspace_stats(assigns.tree))

    ~H"""
    <.page_shell
      breadcrumbs={[{"Loopyard", nil}]}
      iex_session={@iex_session}
      max_width={:lg}
      flash={@flash}
    >
      <header class="mb-6">
        <h1 class="text-2xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">
          Dashboard
        </h1>
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mt-1">Live status across Loopyard.</p>
      </header>

      <.dashboard_grid>
        <%!-- Workspaces --%>
        <.dashboard_card
          navigate="/workspaces"
          title="Workspaces"
          tone={if @ws.working > 0, do: :ok, else: :neutral}
          status={if @ws.working > 0, do: "#{@ws.working} working", else: nil}
        >
          <div class="text-zinc-700 dark:text-zinc-200 font-medium">
            {@ws.projects} {plural(@ws.projects, "project")} · {@ws.agents} {plural(
              @ws.agents,
              "agent"
            )}
          </div>
          <div class="mt-0.5">
            {@ws.workspaces} {plural(@ws.workspaces, "workspace")}{if @ws.working > 0,
              do: " · #{@ws.working} working now",
              else: ""}
          </div>
        </.dashboard_card>

        <%!-- Remote --%>
        <.dashboard_card
          navigate="/remote/"
          title="Remote"
          tone={if @remote_exposed, do: :ok, else: :neutral}
          status={if @remote_exposed, do: "exposed", else: "private"}
        >
          <div :if={@remote_exposed} class="text-zinc-700 dark:text-zinc-200">
            Reachable on your network
          </div>
          <div :if={@remote_exposed} class="mt-0.5 font-mono text-xs">{@host}</div>
          <div :if={!@remote_exposed}>Private — only this machine can reach it.</div>
        </.dashboard_card>

        <%!-- System --%>
        <.dashboard_card
          navigate="/system"
          title="System"
          tone={health_tone(@health)}
          status={to_string(@health)}
        >
          <div class="text-zinc-700 dark:text-zinc-200">{health_line(@health)}</div>
        </.dashboard_card>

        <%!-- Operator — opens the operator agent for the current identity --%>
        <.dashboard_card
          navigate="/operator"
          title="Operator"
          tone={:neutral}
          status={@operator}
        >
          <div class="text-zinc-700 dark:text-zinc-200">
            Talk to your operator agent
          </div>
          <div class="mt-0.5">
            as <span class="font-medium">{@operator}</span>
          </div>
        </.dashboard_card>

        <%!-- Workstations — the identities (users) that run inside the containers:
    their creds, image, and env. The home for setting up + switching
    identities (reached from here, not a top-right menu). --%>
        <.dashboard_card
          navigate="/workstations"
          title="Workstations"
          tone={:neutral}
          status={"#{@operator_count} #{plural(@operator_count, "workstation")}"}
        >
          <div class="text-zinc-700 dark:text-zinc-200">
            Identities that run in the containers — creds, image, env
          </div>
          <div class="mt-0.5">
            operating as <span class="font-medium">{@operator}</span>
          </div>
        </.dashboard_card>
      </.dashboard_grid>
    </.page_shell>
    """
  end

  # ── derived values ────────────────────────────────────────────────────────

  defp workspace_stats(tree) do
    agents = Enum.flat_map(tree, fn p -> Enum.flat_map(p.workspaces, & &1.agents) end)

    %{
      projects: length(tree),
      workspaces: Enum.sum(Enum.map(tree, &length(&1.workspaces))),
      agents: length(agents),
      working: Enum.count(agents, &(&1.status == :thinking))
    }
  end

  defp health_tone(:healthy), do: :ok
  defp health_tone(:degraded), do: :warn
  defp health_tone(:down), do: :down
  defp health_tone(_), do: :neutral

  defp health_line(:healthy) do
    n = length(Loopyard.Health.components())
    "All #{n} subsystems healthy"
  rescue
    _ -> "All subsystems healthy"
  end

  defp health_line(:degraded), do: "A subsystem is degraded — tap for detail"
  defp health_line(:down), do: "A subsystem is down — tap for detail"
  defp health_line(_), do: "Status unavailable"

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
