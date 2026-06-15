defmodule LoopyardWeb.WorkstationToolLive do
  @moduledoc """
  One page per integration (`/workstations/:id/:tool`). **Mac-first**: the default
  is a single command you run on your Mac that pipes the credential into the box.
  "Set a token" and "Use the terminal" live under *Other ways*. The doc is tucked
  under *Reference*. See plans/integrations.md.
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  alias Loopyard.Terminal
  alias Loopyard.Workstation
  alias Loopyard.Workstation.{Container, Env, Integration}

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
        # Operating-as follows the workstation in the URL.
        _ = Workstation.set_current(ws)
        ig = Integration.get(tool)
        mac = Integration.mac_command(ig, base_url(), ws)

        doc =
          case Integration.doc(tool) do
            {:ok, md} -> fill(md, ws)
            _ -> "_No reference yet for #{ig.label}._"
          end

        socket =
          if connected?(socket),
            do: subscribe_iex(socket),
            else: assign(socket, :iex_session, %{level: nil})

        socket =
          socket
          |> assign(:ig, ig)
          |> assign(:current_id, ws)
          |> assign(:mac_cmd, mac)
          |> assign(:doc, doc)
          |> assign(:status, :checking)
          |> assign(:console_container, nil)
          |> assign(:console_error, nil)
          |> assign(:term_nonce, 0)

        socket =
          if connected?(socket) do
            # Bring the shared console up only if this tool offers a terminal path.
            socket = if ig.console, do: start_async(socket, :ensure_console, fn -> Container.ensure_up(ws) end), else: socket
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
       |> put_flash(:info, "Running #{cmd} in the console — follow the prompts.")}
    else
      {:noreply, put_flash(socket, :error, "Console still starting — try again in a moment.")}
    end
  end

  def handle_event("save_env", %{"value" => value}, socket) do
    %{ig: ig, current_id: ws} = socket.assigns

    case String.trim(value) do
      "" ->
        {:noreply, put_flash(socket, :error, "Paste a value first.")}

      token ->
        case Env.put(ig.env, token, ws) do
          :ok ->
            {:noreply, put_flash(socket, :info, "Saved #{ig.env} — Restart the workstation to apply.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't save #{ig.env}.")}
        end
    end
  end

  def handle_event("recheck", _params, socket) do
    %{ig: ig, current_id: ws} = socket.assigns

    {:noreply,
     socket
     |> assign(:status, :checking)
     |> start_async(:status, fn -> Integration.connected?(ig, ws) end)}
  end

  # Fill doc placeholders: $LOOPYARD → this server, $WS → the workstation.
  defp fill(md, ws) do
    md
    |> String.replace("$LOOPYARD", base_url())
    |> String.replace("$WS", ws)
  end

  defp base_url, do: "http://localhost:#{port()}"
  defp port, do: LoopyardWeb.Endpoint.config(:http)[:port] || 4000

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[
        {"Workstations", "/workstations"},
        {@current_id, "/workstations/#{@current_id}"},
        {@ig.label, nil}
      ]}
      iex_session={@iex_session}
      max_width={:md}
      flash={@flash}
    >
      <div id="ws-page" phx-hook="WsScroll" class="max-w-xl space-y-8">
        <%!-- Header: what this is + status --%>
        <div class="space-y-1">
          <div class="flex items-center justify-between gap-3">
            <h1 class="text-xl font-semibold tracking-tight">Connect {@ig.label}</h1>
            <.status_badge status={@status} />
          </div>
          <p class="text-sm text-zinc-500 dark:text-zinc-400 leading-relaxed">{@ig.blurb}</p>
        </div>

        <%!-- DEFAULT: run it on your Mac --%>
        <section class="space-y-3">
          <div>
            <h2 class="text-sm font-medium text-zinc-800 dark:text-zinc-100">Run this on your Mac</h2>
            <p class="text-xs text-zinc-500 dark:text-zinc-400">
              On the machine where you're already logged in — it pipes the credential into this workstation.
            </p>
          </div>

          <div class="flex items-stretch gap-2">
            <pre class="flex-1 overflow-x-auto rounded-lg bg-zinc-900 dark:bg-zinc-950 text-zinc-100 text-[11px] leading-relaxed font-mono px-3 py-2.5 ring-1 ring-zinc-800">{@mac_cmd}</pre>
            <button
              id="clip-mac"
              type="button"
              phx-hook="Clip"
              data-label="Copy"
              data-copy={@mac_cmd}
              class="focus-ring flex-none self-start rounded-lg bg-zinc-900 hover:bg-zinc-700 text-white dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-white px-3.5 py-2.5 text-xs font-medium transition-colors"
            >
              Copy
            </button>
          </div>

          <div class="flex items-center gap-4 text-[11px] text-zinc-400 dark:text-zinc-500">
            <button phx-click="recheck" class="focus-ring hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">
              ↻ Re-check
            </button>
            <span>Lands in {@ig.lands}</span>
          </div>
        </section>

        <%!-- Other ways: env token, terminal — collapsed by default --%>
        <details :if={@ig.env || @ig.console} class="group rounded-lg border border-zinc-200 dark:border-zinc-800">
          <summary class="cursor-pointer list-none flex items-center gap-2 px-3.5 py-2.5 text-xs font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200">
            <svg class="w-3 h-3 group-open:rotate-90 transition-transform" viewBox="0 0 12 12" fill="none" aria-hidden="true">
              <path d="M4.5 3 7.5 6 4.5 9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
            </svg>
            Other ways
          </summary>

          <div class="px-3.5 pb-4 pt-1 space-y-5 border-t border-zinc-100 dark:border-zinc-800">
            <%!-- Set a token --%>
            <form :if={@ig.env} phx-submit="save_env" class="space-y-2 pt-3">
              <div>
                <h3 class="text-xs font-medium text-zinc-700 dark:text-zinc-200">Set a token</h3>
                <p class="text-[11px] text-zinc-400 dark:text-zinc-500">
                  Paste <span class="font-mono">{@ig.env}</span> — Restart to apply.
                </p>
              </div>
              <div class="flex gap-2">
                <input
                  type="password"
                  name="value"
                  autocomplete="off"
                  placeholder={"paste #{@ig.env}"}
                  class="flex-1 rounded-lg border border-zinc-200 dark:border-zinc-700 bg-transparent px-3 py-2 text-sm font-mono placeholder:font-sans placeholder:text-zinc-400 focus-ring"
                />
                <button type="submit" class="focus-ring flex-none rounded-lg bg-zinc-900 hover:bg-zinc-700 text-white dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-white px-3.5 py-2 text-xs font-medium transition-colors">
                  Save
                </button>
              </div>
            </form>

            <%!-- Use the terminal --%>
            <div :if={@ig.console} class="space-y-2 pt-1">
              <div class="flex items-center justify-between gap-2">
                <h3 class="text-xs font-medium text-zinc-700 dark:text-zinc-200">Use the terminal</h3>
                <button
                  type="button"
                  phx-click="run_in_console"
                  phx-value-cmd={@ig.console}
                  class="focus-ring rounded-md border border-zinc-200 dark:border-zinc-700 px-2.5 py-1 text-[11px] font-mono text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
                >
                  ▶ {@ig.console}
                </button>
              </div>
              <div id="ws-console" class="rounded-lg overflow-hidden h-[44dvh] min-h-[280px] bg-[#18181b]">
                <div
                  :if={@console_container}
                  id={"terminal-#{@console_container}-#{@term_nonce}"}
                  phx-hook="Terminal"
                  data-container={@console_container}
                  phx-update="ignore"
                  class="h-full p-2 overflow-hidden"
                >
                </div>
                <div :if={!@console_container} class="h-full flex items-center justify-center text-xs text-zinc-500">
                  Starting console…
                </div>
              </div>
            </div>
          </div>
        </details>

        <%!-- Reference doc — collapsed; child .markdown-body is where the hook renders --%>
        <details class="group">
          <summary class="cursor-pointer list-none flex items-center gap-2 text-xs font-medium text-zinc-400 dark:text-zinc-500 hover:text-zinc-600 dark:hover:text-zinc-300">
            <svg class="w-3 h-3 group-open:rotate-90 transition-transform" viewBox="0 0 12 12" fill="none" aria-hidden="true">
              <path d="M4.5 3 7.5 6 4.5 9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
            </svg>
            Reference
          </summary>
          <div id="ws-tool-doc" phx-hook="Markdown" data-source={@doc} class="mt-3">
            <div class="markdown-body text-sm text-zinc-700 dark:text-zinc-300"></div>
          </div>
        </details>
      </div>
    </.page_shell>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span
      :if={@status == :connected}
      class="flex-none text-xs font-medium rounded-full px-2.5 py-1 bg-emerald-100 dark:bg-emerald-950/50 text-emerald-700 dark:text-emerald-400"
    >
      Connected
    </span>
    <span
      :if={@status == :not_connected}
      class="flex-none text-xs font-medium rounded-full px-2.5 py-1 bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-400"
    >
      Not connected
    </span>
    <span
      :if={@status == :checking}
      class="flex-none text-xs rounded-full px-2.5 py-1 bg-zinc-100 dark:bg-zinc-800 text-zinc-400 animate-pulse"
    >
      Checking…
    </span>
    """
  end
end
