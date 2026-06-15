defmodule LoopyardWeb.WorkstationToolLive do
  @moduledoc """
  A page per integration (`/workstation/:tool`) — the doc for the tool plus the
  setup widget for its method: an embedded console + ▶ Run for `:console` tools
  (GitHub's `gh auth login`), a 📋 Copy-for-Mac for `:file`/`:env` tools (Codex,
  Claude, Fly). Async status probe. See plans/integrations.md.
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  alias Loopyard.Terminal
  alias Loopyard.Workstation
  alias Loopyard.Workstation.{Container, Integration}

  @impl true
  def mount(%{"id" => ws, "tool" => tool}, _session, socket) do
    cond do
      not Workstation.exists?(ws) ->
        {:ok,
         socket
         |> put_flash(:error, "No workstation \"#{ws}\".")
         |> push_navigate(to: "/workstations/#{Workstation.current()}")}

      is_nil(Integration.get(tool)) ->
        {:ok,
         socket |> put_flash(:error, "Unknown tool: #{tool}") |> push_navigate(to: "/workstations/#{ws}")}

      true ->
        # Operating-as follows the workstation in the URL; it's baked into the
        # Copy-for-Mac command + the doc's curl examples so they name which
        # workstation to push to.
        _ = Workstation.set_current(ws)
        ig = Integration.get(tool)

        socket =
          if connected?(socket),
            do: subscribe_iex(socket),
            else: assign(socket, :iex_session, %{level: nil})

        doc =
          case Integration.doc(tool) do
            {:ok, md} -> fill(md, ws)
            _ -> "_No doc yet for #{ig.label}._"
          end

        socket =
          socket
          |> assign(:ig, ig)
          |> assign(:doc, doc)
          |> assign(:status, :checking)
          |> assign(:console_container, nil)
          |> assign(:console_error, nil)
          |> assign(:term_nonce, 0)
          |> assign(:http_port, port())
          |> assign(:current_id, ws)
          |> assign(:mac_cmd, mac_cmd(ig, ws))

        socket =
          if connected?(socket) do
            socket =
              if ig.method == :console,
                do: start_async(socket, :ensure_console, fn -> Container.ensure_up(ws) end),
                else: socket

            start_async(socket, :status, fn -> Integration.connected?(ig, ws) end)
          else
            socket
          end

        {:ok, socket}
    end
  end

  @impl true
  def handle_async(:ensure_console, {:ok, {:ok, name}}, socket),
    do: {:noreply, assign(socket, :console_container, name)}

  def handle_async(:ensure_console, {_, reason}, socket),
    do: {:noreply, assign(socket, :console_error, inspect(reason))}

  def handle_async(:status, {:ok, connected?}, socket),
    do: {:noreply, assign(socket, :status, if(connected?, do: :connected, else: :not_connected))}

  def handle_async(:status, {:exit, _}, socket),
    do: {:noreply, assign(socket, :status, :not_connected)}

  @impl true
  def handle_event("run_in_console", %{"cmd" => cmd}, socket) do
    if socket.assigns.console_container do
      Terminal.send_input(socket.assigns.console_container, cmd <> "\n")

      {:noreply,
       socket
       |> push_event("ws_focus_console", %{})
       |> put_flash(:info, "Running `#{cmd}` in the console — follow the prompts.")}
    else
      {:noreply, put_flash(socket, :error, "Console still starting — try again in a moment.")}
    end
  end

  def handle_event("recheck", _params, socket) do
    %{ig: ig, current_id: ws} = socket.assigns

    {:noreply,
     socket
     |> assign(:status, :checking)
     |> start_async(:status, fn -> Integration.connected?(ig, ws) end)}
  end

  # Fill doc placeholders: $LOOPYARD → this server, $WS → the current identity
  # (concrete, so the rendered curl is copy-paste ready).
  defp fill(md, ws) do
    md
    |> String.replace("$LOOPYARD", "http://localhost:#{port()}")
    |> String.replace("$WS", ws)
  end

  defp port, do: LoopyardWeb.Endpoint.config(:http)[:port] || 4000

  defp mac_cmd(%{method: :file, mac: mac, file: file}, ws),
    do: "#{mac} | curl -fsS -T - http://localhost:#{port()}/workstations/#{ws}/file/#{file}"

  defp mac_cmd(%{method: :env, mac: mac, env: env}, ws),
    do: "#{mac} | curl -fsS -T - http://localhost:#{port()}/workstations/#{ws}/env/#{env}"

  defp mac_cmd(_, _ws), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[
        {"Loopyard", "/"},
        {"Workstations", "/workstations"},
        {@current_id, "/workstations/#{@current_id}"},
        {@ig.label, nil}
      ]}
      iex_session={@iex_session}
      max_width={:lg}
      flash={@flash}
    >
      <div id="ws-page" phx-hook="WsScroll" class="space-y-5">
        <div class="flex items-center justify-between gap-3">
          <h2 class="text-lg md:text-xl font-semibold">Connect {@ig.label}</h2>
          <.status_badge status={@status} />
        </div>

        <%!-- Setup widget: console+Run for :console, Copy-for-Mac for :file/:env --%>
        <div class="rounded-xl border border-violet-200 dark:border-violet-800 bg-violet-50/50 dark:bg-violet-950/20 p-4">
          <div :if={@ig.method == :console}>
            <button
              type="button"
              phx-click="run_in_console"
              phx-value-cmd={@ig.console}
              class="focus-ring inline-flex items-center gap-1.5 rounded-lg bg-violet-600 hover:bg-violet-700 text-white px-4 py-2 text-sm font-semibold transition-colors"
            >
              ▶ Run <span class="font-mono">{@ig.console}</span>
            </button>
            <span class="ml-2 text-xs text-zinc-500 dark:text-zinc-400">in the console below, then follow the steps</span>
          </div>

          <div :if={@mac_cmd} class="flex items-center gap-2">
            <pre class="flex-1 overflow-x-auto rounded-md bg-zinc-950 text-zinc-200 text-[11px] font-mono px-3 py-2">{@mac_cmd}</pre>
            <button
              id="clip-mac"
              type="button"
              phx-hook="Clip"
              data-label="📋 Copy for Mac"
              data-copy={@mac_cmd}
              class="focus-ring flex-none rounded-md bg-violet-600 hover:bg-violet-700 text-white px-3 py-2 text-xs font-semibold"
            >
              📋 Copy for Mac
            </button>
          </div>

          <div class="mt-2 flex items-center gap-3">
            <button phx-click="recheck" class="focus-ring text-[11px] text-violet-600 dark:text-violet-400 hover:underline">
              ↻ Re-check status
            </button>
            <span class="text-[11px] text-zinc-400 dark:text-zinc-500">lands in {@ig.lands}</span>
          </div>
        </div>

        <%!-- The doc — single source for humans + agents (also at /workstation/:tool/docs.md). --%>
        <div class="rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 md:p-5">
          <div
            id="ws-tool-doc"
            phx-hook="Markdown"
            data-source={@doc}
            class="markdown-body text-sm text-zinc-800 dark:text-zinc-200"
          >
          </div>
        </div>

        <%!-- Embedded console for :console tools — same shared session as the workstation. --%>
        <div :if={@ig.method == :console} id="ws-console" class="rounded-xl border border-zinc-200 dark:border-zinc-700 overflow-hidden h-[58dvh] min-h-[340px] flex flex-col">
          <div class="flex-none px-3 py-1.5 border-b border-zinc-200 dark:border-zinc-700 text-[11px] text-zinc-500 dark:text-zinc-400">
            Console — shared with the workstation
          </div>
          <div class="flex-1 min-h-0 p-2">
            <div
              :if={@console_container}
              id={"terminal-#{@console_container}-#{@term_nonce}"}
              phx-hook="Terminal"
              data-container={@console_container}
              phx-update="ignore"
              class="h-full bg-[#18181b] rounded-lg p-2 overflow-hidden"
            >
            </div>
            <div
              :if={!@console_container}
              class="h-full bg-[#18181b] rounded-lg flex items-center justify-center text-sm text-zinc-500"
            >
              Starting console…
            </div>
          </div>
        </div>
      </div>
    </.page_shell>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span
      :if={@status == :connected}
      class="text-xs font-medium rounded-full px-2.5 py-1 bg-emerald-100 dark:bg-emerald-950/50 text-emerald-700 dark:text-emerald-400"
    >
      ✓ Connected
    </span>
    <span
      :if={@status == :not_connected}
      class="text-xs font-medium rounded-full px-2.5 py-1 bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-400"
    >
      Not connected
    </span>
    <span
      :if={@status == :checking}
      class="text-xs rounded-full px-2.5 py-1 bg-zinc-100 dark:bg-zinc-800 text-zinc-400 animate-pulse"
    >
      checking…
    </span>
    """
  end
end
