defmodule LoopyardWeb.WorkstationLive do
  @moduledoc """
  The **Workstation** page — your machine, configured conversationally.

  Three surfaces, in priority order:

    * **Chat** with the workstation agent (`Loopyard.Workstation.Agent`): "add the
      aws cli" → it edits the Dockerfile + rebuilds while you watch. The primary
      way to configure the box.
    * **Console** — a shell on the live workstation container, for the logins only
      you can do (`gh auth login`, `claude login`, `fly auth login`). Persists in
      the `$HOME` volume; every agent inherits it.
    * **Image / Dockerfile** — the base image every agent is stamped from. The
      agent edits this for you, but you can hand-edit + Save & Rebuild too.

  Build output streams to the build pane via `Events.Workstation` whether the
  human or the agent kicked it off — multiplayer by default. See
  plans/workstations.md.
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  import LoopyardWeb.Live.WorkspaceLive.Components.Chat, only: [chat_panel: 1]

  alias Loopyard.ChatAgent
  alias Loopyard.Events
  alias Loopyard.Terminal
  alias Loopyard.Workstation.{Agent, Container, Env, Image}

  @behaviour Events.ChatAgentMessage.Subscriber
  @behaviour Events.Workstation.Subscriber

  @impl true
  def mount(_params, _session, socket) do
    agent_id = Agent.id()

    socket =
      if connected?(socket) do
        Events.ChatAgentMessage.subscribe(agent_id)
        Events.Workstation.subscribe()
        subscribe_iex(socket)
      else
        assign(socket, :iex_session, %{level: nil})
      end

    dockerfile =
      case Image.read_dockerfile() do
        {:ok, d} -> d
        _ -> ""
      end

    socket =
      socket
      |> assign(:agent_id, agent_id)
      |> assign(:agent, %{id: agent_id, status: :booting})
      |> assign(:agent_ready, false)
      |> assign(:agent_error, nil)
      |> assign(:messages, [])
      |> assign(:streaming_text, "")
      |> assign(:streaming_thinking, "")
      |> assign(:thinking_word, "thinking")
      |> assign(:dockerfile, dockerfile)
      |> assign(:image, Image.status())
      |> assign(:building, false)
      |> assign(:build_output, "")
      |> assign(:build_result, nil)
      |> assign(:console_container, nil)
      |> assign(:console_error, nil)
      |> assign(:tab, :console)
      |> assign(:term_nonce, 0)
      |> assign(:restarting, false)
      |> assign_env()

    # Bring the console container + the agent up off the LV process — both can
    # block (create container / boot a CLI session). The UI renders once ready.
    socket =
      if connected?(socket) do
        socket
        |> start_async(:ensure_console, fn -> Container.ensure_up() end)
        |> start_async(:ensure_agent, fn -> Agent.ensure_started() end)
      else
        socket
      end

    {:ok, socket}
  end

  # --- async boots ---

  @impl true
  def handle_async(:ensure_console, {:ok, {:ok, name}}, socket),
    do: {:noreply, assign(socket, :console_container, name)}

  def handle_async(:ensure_console, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :console_error, inspect(reason))}

  def handle_async(:ensure_console, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :console_error, inspect(reason))}

  def handle_async(:ensure_agent, {:ok, {:ok, id}}, socket) do
    {:noreply, socket |> assign(:agent_ready, true) |> refresh_agent(id)}
  end

  def handle_async(:ensure_agent, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :agent_error, inspect(reason))}

  def handle_async(:ensure_agent, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :agent_error, inspect(reason))}

  def handle_async(:restart_machine, {:ok, {:ok, name}}, socket) do
    # Bump the nonce so the terminal hook remounts and reconnects to the fresh
    # container instead of clinging to the dead exec.
    {:noreply,
     socket
     |> assign(:restarting, false)
     |> assign(:console_container, name)
     |> assign(:term_nonce, socket.assigns.term_nonce + 1)}
  end

  def handle_async(:restart_machine, {:ok, {:error, reason}}, socket),
    do: {:noreply, socket |> assign(:restarting, false) |> assign(:console_error, inspect(reason))}

  def handle_async(:restart_machine, {:exit, reason}, socket),
    do: {:noreply, socket |> assign(:restarting, false) |> assign(:console_error, inspect(reason))}

  def handle_async({:import_token, key}, {:ok, {:ok, output}}, socket) do
    token = String.trim(output)

    if token != "" and not String.contains?(token, " ") and not String.contains?(token, "\n") do
      Env.put(key, token)

      {:noreply,
       socket |> assign_env() |> put_flash(:info, "Imported #{key} — Restart the machine to apply.")}
    else
      {:noreply,
       put_flash(socket, :error, "Couldn't read a token (is the tool logged in? try the console).")}
    end
  end

  def handle_async({:import_token, key}, {:ok, {:error, _}}, socket),
    do:
      {:noreply,
       put_flash(socket, :error, "Couldn't import #{key} — log the tool in first (e.g. `gh auth login`).")}

  def handle_async({:import_token, _key}, {:exit, reason}, socket),
    do: {:noreply, put_flash(socket, :error, "Import failed: #{inspect(reason)}")}

  # --- chat input ---

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    message = String.trim(message)

    if message != "" and socket.assigns.agent_ready do
      ChatAgent.send_message(socket.assigns.agent_id, message)
      # Optimistic: flip to thinking so the indicator shows before the echo.
      {:noreply, assign(socket, :agent, %{socket.assigns.agent | status: :thinking})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_env", %{"name" => name, "value" => value}, socket) do
    case Env.put(name, value) do
      :ok ->
        {:noreply,
         socket
         |> assign_env()
         |> put_flash(:info, "Saved #{String.trim(name)} — Restart the machine to apply.")}

      {:error, :invalid_key} ->
        {:noreply, put_flash(socket, :error, "Invalid env var name (use A–Z, 0–9, _).")}
    end
  end

  def handle_event("delete_env", %{"key" => key}, socket) do
    Env.delete(key)

    {:noreply,
     socket
     |> assign_env()
     |> put_flash(:info, "Removed #{key} — Restart the machine to apply.")}
  end

  def handle_event("import_token", %{"key" => key}, socket) do
    case Enum.find(Env.integrations(), &(&1.key == key && is_binary(&1.cli))) do
      %{cli: cli} = ig ->
        {:noreply,
         socket
         |> put_flash(:info, "Importing #{key} via `#{ig.cli}`…")
         |> start_async({:import_token, key}, fn -> Container.exec(cli) end)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("run_in_console", %{"cmd" => cmd}, socket) do
    # Runnable docs: type the command into the live console + take you to it, so
    # the terminal is where the instruction is (not "go run this elsewhere").
    if socket.assigns.console_container do
      Terminal.send_input(socket.assigns.console_container, cmd <> "\n")

      {:noreply,
       socket
       |> assign(:tab, :console)
       |> push_event("ws_focus_console", %{})
       |> put_flash(:info, "Running `#{cmd}` in the console — follow the prompts there.")}
    else
      {:noreply, put_flash(socket, :error, "Console is still starting — try again in a moment.")}
    end
  end

  def handle_event("switch_tab", %{"tab" => "dockerfile"}, socket),
    do: {:noreply, assign(socket, :tab, :dockerfile)}

  def handle_event("switch_tab", %{"tab" => _}, socket),
    do: {:noreply, assign(socket, :tab, :console)}

  def handle_event("restart_machine", _params, socket) do
    # Recreate the workstation container from scratch — for when the shell wedges.
    # Kill the terminal session first so a fresh `docker exec` lands on the new
    # container; the $HOME volume (logins/dotfiles) is untouched.
    socket =
      socket
      |> assign(:restarting, true)
      |> assign(:console_container, nil)
      |> assign(:tab, :console)
      |> start_async(:restart_machine, fn ->
        Terminal.stop(Container.name())
        Container.down()
        Container.ensure_up()
      end)

    {:noreply, socket}
  end

  # --- Dockerfile editor (manual path) ---

  def handle_event("apply", %{"action" => action, "dockerfile" => df}, socket) do
    case Image.write_dockerfile(df) do
      :ok ->
        socket = assign(socket, :dockerfile, df)

        if action == "rebuild" and not socket.assigns.building do
          {:noreply, start_build(socket)}
        else
          {:noreply, put_flash(socket, :info, "Saved.")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't save: #{inspect(reason)}")}
    end
  end

  # --- ChatAgentMessage subscriber ---

  @impl Events.ChatAgentMessage.Subscriber
  def on_message(%Events.ChatAgentMessage.Message{agent_id: id, msg: msg}, socket)
      when id == socket.assigns.agent_id do
    if msg[:id] && Enum.any?(socket.assigns.messages, &(&1[:id] == msg[:id])) do
      {:noreply, socket}
    else
      socket =
        if msg.role == :assistant,
          do: assign(socket, streaming_text: "", streaming_thinking: ""),
          else: socket

      socket =
        socket
        |> assign(:messages, socket.assigns.messages ++ [msg])
        |> refresh_agent(id)
        # The agent may have edited the Dockerfile / rebuilt — keep the editor +
        # status in sync after every turn step.
        |> assign(:dockerfile, current_dockerfile(socket))
        |> assign(:image, Image.status())
        |> push_event("scroll_bottom", %{})

      {:noreply, socket}
    end
  end

  def on_message(%Events.ChatAgentMessage.Message{}, socket), do: {:noreply, socket}

  @impl Events.ChatAgentMessage.Subscriber
  def on_text_delta(%Events.ChatAgentMessage.TextDelta{agent_id: id, text: text}, socket)
      when id == socket.assigns.agent_id do
    {:noreply,
     socket
     |> refresh_agent(id)
     |> assign(:streaming_text, socket.assigns.streaming_text <> text)
     |> assign(:streaming_thinking, "")
     |> push_event("scroll_bottom", %{})}
  end

  def on_text_delta(%Events.ChatAgentMessage.TextDelta{}, socket), do: {:noreply, socket}

  @impl Events.ChatAgentMessage.Subscriber
  def on_stream_output(
        %Events.ChatAgentMessage.StreamOutput{agent_id: id, data: data, title: "__thinking__"},
        socket
      )
      when id == socket.assigns.agent_id do
    {:noreply,
     socket
     |> assign(:streaming_thinking, (socket.assigns.streaming_thinking || "") <> data)
     |> push_event("scroll_bottom", %{})}
  end

  def on_stream_output(%Events.ChatAgentMessage.StreamOutput{}, socket), do: {:noreply, socket}

  # --- Workstation (build pane) subscriber ---

  @impl Events.Workstation.Subscriber
  def on_build_output(%Events.Workstation.BuildOutput{data: data}, socket) do
    # First chunk of a fresh build (e.g. agent-triggered) flips the pane on and
    # clears stale output; subsequent chunks append.
    base = if socket.assigns.building, do: socket.assigns.build_output, else: ""
    combined = cap(base <> data)

    {:noreply,
     socket
     |> assign(:building, true)
     |> assign(:build_result, nil)
     |> assign(:build_output, combined)}
  end

  @impl Events.Workstation.Subscriber
  def on_build_done(%Events.Workstation.BuildDone{result: result}, socket) do
    {:noreply,
     socket
     |> assign(:building, false)
     |> assign(:build_result, result)
     |> assign(:image, Image.status())}
  end

  # --- handle_info dispatch (struct -> on_* callback; no macro, per Move #3) ---

  @impl true
  def handle_info(%Events.ChatAgentMessage.Message{} = e, socket), do: on_message(e, socket)
  def handle_info(%Events.ChatAgentMessage.TextDelta{} = e, socket), do: on_text_delta(e, socket)

  def handle_info(%Events.ChatAgentMessage.StreamOutput{} = e, socket),
    do: on_stream_output(e, socket)

  def handle_info(%Events.Workstation.BuildOutput{} = e, socket), do: on_build_output(e, socket)
  def handle_info(%Events.Workstation.BuildDone{} = e, socket), do: on_build_done(e, socket)
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- helpers ---

  defp start_build(socket) do
    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      result = Image.build(fn data -> Events.Workstation.publish(%Events.Workstation.BuildOutput{data: data}) end)
      Events.Workstation.publish(%Events.Workstation.BuildDone{result: result})
    end)

    socket
    |> assign(:building, true)
    |> assign(:build_output, "")
    |> assign(:build_result, nil)
  end

  defp assign_env(socket) do
    keys = Env.keys()
    integration_keys = Enum.map(Env.integrations(), & &1.key)

    socket
    |> assign(:env_keys, keys)
    |> assign(:other_env_keys, keys -- integration_keys)
  end

  defp refresh_agent(socket, id) do
    case ChatAgent.get_state(id) do
      nil -> socket
      summary -> assign(socket, :agent, summary)
    end
  end

  # Re-read the Dockerfile from disk, falling back to the current assign on error.
  defp current_dockerfile(socket) do
    case Image.read_dockerfile() do
      {:ok, d} -> d
      _ -> socket.assigns.dockerfile
    end
  end

  defp cap(s) when byte_size(s) > 64_000,
    do: binary_part(s, byte_size(s) - 64_000, 64_000)

  defp cap(s), do: s

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[{"Loopyard", "/"}, {"Workstation", nil}]}
      iex_session={@iex_session}
      max_width={:xl}
      flash={@flash}
    >
      <div id="ws-page" phx-hook="WsScroll" class="space-y-4">
        <div class="flex items-baseline justify-between gap-3">
          <h2 class="text-lg md:text-xl font-semibold">Workstation</h2>
          <span class="text-[11px] font-mono text-zinc-400 dark:text-zinc-500 truncate">
            {Image.tag()} · {if @image.exists, do: @image.size <> " · built", else: "not built"}
          </span>
        </div>

        <%!-- Two columns: a prominent Console|Dockerfile tab panel, and the agent
             chat always visible alongside. Stacks on mobile. --%>
        <div class="flex flex-col lg:flex-row gap-4 lg:h-[calc(100dvh-9.5rem)]">
          <%!-- LEFT: Console / Dockerfile tabs (terminal is the default).
               dvh (not vh) so iOS Safari's address bar is accounted for. --%>
          <div id="ws-console" class="flex flex-col min-h-0 lg:flex-[3] h-[68dvh] lg:h-auto rounded-xl border border-zinc-200 dark:border-zinc-700 overflow-hidden">
            <div class="flex-none flex items-center gap-1 px-2 border-b border-zinc-200 dark:border-zinc-700">
              <button phx-click="switch_tab" phx-value-tab="console" class={tab_class(@tab == :console)}>
                Console
              </button>
              <button phx-click="switch_tab" phx-value-tab="dockerfile" class={tab_class(@tab == :dockerfile)}>
                Dockerfile
              </button>
              <div class="ml-auto flex items-center gap-2 pr-1">
                <span class="text-[11px] text-zinc-400 dark:text-zinc-500 hidden md:block">
                  {if @tab == :console, do: "logins persist in $HOME", else: "baked into every agent"}
                </span>
                <button
                  phx-click="restart_machine"
                  disabled={@restarting}
                  title="Recreate the workstation container (your $HOME / logins are kept)"
                  class="focus-ring inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100 hover:bg-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-50 transition-colors"
                >
                  <svg
                    class={["w-3.5 h-3.5", @restarting && "animate-spin"]}
                    xmlns="http://www.w3.org/2000/svg"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    stroke-width="2"
                  >
                    <path stroke-linecap="round" stroke-linejoin="round" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
                  </svg>
                  {if @restarting, do: "Restarting…", else: "Restart"}
                </button>
              </div>
            </div>

            <%!-- Console body — the terminal stays mounted and is hidden (not removed)
                 when inactive, so switching tabs never drops the shell session. --%>
            <div class={["flex-1 min-h-0 p-2", @tab != :console && "hidden"]}>
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
                :if={!@console_container && !@console_error}
                class="h-full bg-[#18181b] rounded-lg flex items-center justify-center text-sm text-zinc-500"
              >
                <span class="inline-flex items-center gap-2">
                  <.spinner /> {if @restarting, do: "Restarting the machine…", else: "Starting your console…"}
                </span>
              </div>
              <div
                :if={@console_error}
                class="rounded-lg border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/30 p-3 text-sm text-red-600 dark:text-red-400"
              >
                Couldn't start the workstation console: {@console_error}
              </div>
            </div>

            <%!-- Dockerfile body — the whole tab is the editor form. --%>
            <form
              phx-submit="apply"
              class={["flex-1 min-h-0 flex flex-col gap-3 p-3", @tab != :dockerfile && "hidden"]}
            >
              <div class="flex-none flex items-center gap-2">
                <button
                  type="submit"
                  name="action"
                  value="rebuild"
                  disabled={@building}
                  class="focus-ring inline-flex items-center justify-center gap-1.5 rounded-lg bg-violet-600 hover:bg-violet-700 disabled:opacity-60 text-white px-4 py-2 text-sm font-semibold transition-colors"
                >
                  {if @building, do: "Building…", else: "Save & Rebuild"}
                </button>
                <button
                  type="submit"
                  name="action"
                  value="save"
                  disabled={@building}
                  class="focus-ring inline-flex items-center rounded-lg border border-zinc-300 dark:border-zinc-600 px-4 py-2 text-sm font-medium text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-60 transition-colors"
                >
                  Save
                </button>
                <span class="ml-auto text-[11px] text-zinc-400 dark:text-zinc-500 hidden sm:block">
                  changes every agent's image
                </span>
              </div>
              <textarea
                name="dockerfile"
                spellcheck="false"
                autocapitalize="off"
                autocomplete="off"
                autocorrect="off"
                class="flex-1 min-h-0 w-full resize-none font-mono text-xs leading-relaxed rounded-lg border border-zinc-300 dark:border-zinc-700 bg-zinc-950 text-zinc-100 p-3
                       focus:outline-none focus:ring-2 focus:ring-violet-500/30 focus:border-violet-400"
              >{@dockerfile}</textarea>
            </form>
          </div>

          <%!-- RIGHT: the agent chat, always visible. --%>
          <div
            id="chat-page"
            phx-hook="ScrollBottom"
            class="flex flex-col min-h-0 lg:flex-[2] h-[60dvh] lg:h-auto rounded-xl border border-zinc-200 dark:border-zinc-700 overflow-hidden"
          >
            <div class="flex-none px-4 py-2 border-b border-zinc-200 dark:border-zinc-700 text-xs font-medium text-zinc-500 dark:text-zinc-400">
              Agent — tell it what to install
            </div>
            <div :if={@agent_ready} class="flex-1 flex flex-col min-h-0">
              <.chat_panel
                messages={@messages}
                agent={@agent}
                workspace_id={nil}
                host="localhost"
                streaming_text={@streaming_text}
                streaming_thinking={@streaming_thinking}
                thinking_word={@thinking_word}
              />
            </div>
            <div
              :if={!@agent_ready && !@agent_error}
              class="flex-1 flex items-center justify-center text-sm text-zinc-500"
            >
              <span class="inline-flex items-center gap-2"><.spinner /> Waking the workstation agent…</span>
            </div>
            <div
              :if={@agent_error}
              class="flex-1 flex items-center justify-center p-4 text-sm text-red-600 dark:text-red-400 text-center"
            >
              Couldn't start the workstation agent: {@agent_error}
            </div>
          </div>
        </div>

        <%!-- Environment — token slots stamped into the console + every agent. --%>
        <div class="rounded-xl border border-zinc-200 dark:border-zinc-700 p-4">
          <div class="flex items-baseline justify-between gap-2 mb-3">
            <div class="text-sm font-medium">Connect your tools</div>
            <div class="text-[11px] text-zinc-400 dark:text-zinc-500">
              one token each · every agent + the console inherit it · Restart to apply
            </div>
          </div>

          <%!-- Guided integration slots: pick the tool, paste the token. --%>
          <div class="grid gap-3 sm:grid-cols-3">
            <div
              :for={ig <- Env.integrations()}
              class="rounded-lg border border-zinc-200 dark:border-zinc-700 p-3 flex flex-col"
            >
              <div class="flex items-center justify-between gap-2">
                <span class="flex items-center gap-1.5 min-w-0">
                  <span class="text-sm font-medium">{ig.label}</span>
                  <span
                    :if={ig.setup == :desktop}
                    title="Minting this token needs a desktop browser (loopback OAuth)"
                    class="text-[9px] uppercase tracking-wide rounded px-1 py-px bg-amber-100 dark:bg-amber-950/50 text-amber-700 dark:text-amber-400 flex-none"
                  >
                    desktop
                  </span>
                </span>
                <span
                  :if={ig.key in @env_keys}
                  class="text-[10px] font-medium text-emerald-600 dark:text-emerald-400 flex-none"
                >
                  ✓ set
                </span>
                <span
                  :if={ig.key not in @env_keys}
                  class="text-[10px] text-zinc-400 dark:text-zinc-500 flex-none"
                >
                  not set
                </span>
              </div>
              <div class="font-mono text-[10px] text-zinc-400 dark:text-zinc-500 mt-0.5 truncate">
                {ig.key}
              </div>
              <div class="text-[11px] text-zinc-500 dark:text-zinc-400 mt-1 mb-2 leading-snug">
                {ig.hint}
              </div>
              <form phx-submit="add_env" class="mt-auto flex gap-1.5">
                <input type="hidden" name="name" value={ig.key} />
                <input
                  name="value"
                  type="password"
                  placeholder={if ig.key in @env_keys, do: "update…", else: "paste token"}
                  autocomplete="off"
                  spellcheck="false"
                  class="min-w-0 flex-1 font-mono text-xs rounded-md border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-2 py-1.5 text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
                />
                <button
                  type="submit"
                  class="focus-ring inline-flex items-center rounded-md bg-violet-600 hover:bg-violet-700 text-white px-2.5 py-1.5 text-xs font-semibold transition-colors flex-none"
                >
                  Save
                </button>
                <button
                  :if={ig.key in @env_keys}
                  type="button"
                  phx-click="delete_env"
                  phx-value-key={ig.key}
                  data-confirm={"Clear #{ig.key}?"}
                  class="text-xs text-zinc-400 hover:text-red-500 transition-colors flex-none px-1"
                >
                  Clear
                </button>
              </form>
              <%!-- Runnable docs: type a setup command into the live console. --%>
              <div :if={ig.commands != [] || ig.cli} class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1">
                <button
                  :for={c <- ig.commands}
                  type="button"
                  phx-click="run_in_console"
                  phx-value-cmd={c.cmd}
                  title={"Runs `#{c.cmd}` in the console"}
                  class="focus-ring text-[11px] text-violet-600 dark:text-violet-400 hover:underline"
                >
                  ▶ {c.label}
                </button>
                <button
                  :if={ig.cli}
                  type="button"
                  phx-click="import_token"
                  phx-value-key={ig.key}
                  class="focus-ring text-[11px] text-violet-600 dark:text-violet-400 hover:underline"
                >
                  ↓ {ig.cli_label}
                </button>
              </div>
            </div>
          </div>

          <%!-- Anything else: a plain NAME / value escape hatch + the custom list. --%>
          <details class="mt-4">
            <summary class="cursor-pointer select-none text-xs font-medium text-zinc-500 dark:text-zinc-400">
              Other env vars{if @other_env_keys != [], do: " (#{length(@other_env_keys)})", else: ""}
            </summary>
            <div class="mt-3">
              <form phx-submit="add_env" class="flex flex-col sm:flex-row gap-2 mb-2">
                <input
                  name="name"
                  placeholder="NAME"
                  autocomplete="off"
                  autocapitalize="characters"
                  spellcheck="false"
                  class="sm:w-56 font-mono text-sm rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
                />
                <input
                  name="value"
                  type="password"
                  placeholder="value"
                  autocomplete="off"
                  spellcheck="false"
                  class="flex-1 font-mono text-sm rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
                />
                <button
                  type="submit"
                  class="focus-ring inline-flex items-center justify-center rounded-lg border border-zinc-300 dark:border-zinc-600 px-4 py-2 text-sm font-medium text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors flex-none"
                >
                  Add
                </button>
              </form>
              <ul :if={@other_env_keys != []} class="divide-y divide-zinc-100 dark:divide-zinc-800">
                <li :for={k <- @other_env_keys} class="flex items-center gap-3 py-2">
                  <span class="font-mono text-sm text-zinc-700 dark:text-zinc-300">{k}</span>
                  <span class="font-mono text-xs text-zinc-400 dark:text-zinc-600 select-none">••••••••</span>
                  <button
                    phx-click="delete_env"
                    phx-value-key={k}
                    data-confirm={"Remove #{k}?"}
                    class="ml-auto text-xs text-zinc-400 hover:text-red-500 transition-colors"
                  >
                    Remove
                  </button>
                </li>
              </ul>
            </div>
          </details>
        </div>

        <%!-- Build output — fills live whenever a build runs (agent or manual). --%>
        <div :if={@building || @build_output != ""}>
          <div class="flex items-center justify-between mb-1">
            <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500">
              Build output
            </div>
            <div :if={@building} class="inline-flex items-center gap-1.5 text-xs text-zinc-500 animate-pulse">
              <.spinner /> Building…
            </div>
            <div :if={!@building && @build_result == :ok} class="text-xs font-medium text-emerald-600 dark:text-emerald-400">
              ✓ Built
            </div>
            <div :if={!@building && match?({:error, _}, @build_result)} class="text-xs font-medium text-red-500">
              ✗ Failed
            </div>
          </div>
          <pre
            id="ws-build-output"
            phx-hook="TailScroll"
            class="max-h-72 overflow-auto rounded-lg bg-zinc-950 text-zinc-300 text-[11px] leading-relaxed font-mono p-3 whitespace-pre-wrap"
          >{@build_output}</pre>
        </div>
      </div>
    </.page_shell>
    """
  end

  defp tab_class(active?) do
    base = "px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors focus-ring"

    state =
      if active?,
        do: "border-violet-500 text-violet-600 dark:text-violet-400",
        else:
          "border-transparent text-zinc-500 dark:text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200"

    [base, state]
  end

  defp spinner(assigns) do
    ~H"""
    <svg class="w-3.5 h-3.5 animate-spin" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
      <path
        class="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
      >
      </path>
    </svg>
    """
  end
end
