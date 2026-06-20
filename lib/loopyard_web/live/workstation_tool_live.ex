defmodule LoopyardWeb.WorkstationToolLive do
  @moduledoc """
  One page per integration (`/workstations/:id/:tool`). **Mac-first**: the default
  is a single command you run on your Mac that pipes the credential into the box.
  "Set a token" and "Use the terminal" live under *Other ways*. The doc is tucked
  under *Reference*. See plans/integrations.md.
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  import LoopyardWeb.Components.Workstation

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
        # A clean one-liner that pulls the per-tool script and runs it, instead of
        # pasting a giant blob. (Claude's script mints the durable setup-token.)
        mac = "curl -fsS #{base_url()}/workstations/#{ws}/#{tool}/setup.sh | sh"

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

        socket = if connected?(socket), do: boot(socket, ig, ws), else: socket
        {:ok, socket}
    end
  end

  # Kick off the async probes off the mount body — keeping the slow
  # Container.ensure_up out of mount/handle_params (see LiveViewAsyncContractTest;
  # mirrors WorkstationLive.boot_for_action). Nothing here blocks the first paint.
  defp boot(socket, ig, ws) do
    socket =
      if ig.console,
        do: start_async(socket, :ensure_console, fn -> Container.ensure_up(ws) end),
        else: socket

    start_async(socket, :status, fn -> Integration.connected?(ig, ws) end)
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
      <div id="ws-page" phx-hook="WsScroll" class="space-y-8">
        <%!-- Header: what this is + status --%>
        <div class="space-y-1">
          <div class="flex items-center justify-between gap-3">
            <h1 class="text-xl font-semibold tracking-tight">Connect {@ig.label}</h1>
            <.status_pill status={@status} />
          </div>
          <p class="text-sm text-zinc-500 dark:text-zinc-400 leading-relaxed">{@ig.blurb}</p>
        </div>

        <%!-- DEFAULT: run it on your Mac --%>
        <.section
          title="Run this on your Mac"
          hint="On the machine where you're already logged in — it pipes the credential into this workstation."
        >
          <.command_box id="clip-mac" command={@mac_cmd} />
          <div class="flex items-center gap-4 text-[11px] text-zinc-400 dark:text-zinc-500">
            <button phx-click="recheck" class="focus-ring hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">
              ↻ Re-check
            </button>
            <span>Lands in {@ig.lands}</span>
          </div>
        </.section>

        <%!-- Other ways: env token + terminal — spread out, not collapsed. --%>
        <section :if={@ig.env || @ig.console} class="space-y-5 border-t border-zinc-100 dark:border-zinc-800 pt-6">
          <h2 class="text-sm font-medium text-zinc-500 dark:text-zinc-400">Other ways</h2>

          <%!-- Set a token --%>
          <form :if={@ig.env} phx-submit="save_env" class="space-y-2">
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
              <.button variant={:secondary} type="submit" class="flex-none">Save</.button>
            </div>
          </form>

          <%!-- Use the terminal --%>
          <div :if={@ig.console} class="space-y-2">
            <div class="flex items-center justify-between gap-2">
              <h3 class="text-xs font-medium text-zinc-700 dark:text-zinc-200">Use the terminal</h3>
              <button
                type="button"
                phx-click="run_in_console"
                phx-value-cmd={@ig.console}
                class="focus-ring rounded-md border border-zinc-200 dark:border-zinc-700 px-2.5 py-1 text-[11px] font-mono text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
              >
                ▶ {@ig[:console_label] || @ig.console}
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
        </section>

        <%!-- Reference doc — inline; child .markdown-body is where the hook renders. --%>
        <section class="space-y-2 border-t border-zinc-100 dark:border-zinc-800 pt-6">
          <h2 class="text-sm font-medium text-zinc-500 dark:text-zinc-400">Reference</h2>
          <div id="ws-tool-doc">
            <div class="markdown-body text-sm text-zinc-700 dark:text-zinc-300">
              {Loopyard.Markdown.to_html(@doc)}
            </div>
          </div>
        </section>
      </div>
    </.page_shell>
    """
  end

end
