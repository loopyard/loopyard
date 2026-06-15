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
  import LoopyardWeb.Components.Workstation

  alias Loopyard.ChatAgent
  alias Loopyard.Events
  alias Loopyard.Terminal
  alias Loopyard.Workstation.{Agent, Container, Env, Image, Integration}

  @behaviour Events.ChatAgentMessage.Subscriber
  @behaviour Events.Workstation.Subscriber

  @impl true
  def mount(%{"id" => ws}, _session, socket) do
    if Loopyard.Workstation.exists?(ws) do
      mount_workstation(ws, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, "No workstation \"#{ws}\".")
       |> push_navigate(to: "/workstations/#{Loopyard.Workstation.current()}")}
    end
  end

  # The page operates on the workstation in the URL. Visiting it makes it the
  # identity you're operating as (what new agents inherit). `ws` is threaded into
  # every Image/Env/Container call below — no implicit "current" default.
  defp mount_workstation(ws, socket) do
    _ = Loopyard.Workstation.set_current(ws)
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
      case Image.read_dockerfile(ws) do
        {:ok, d} -> d
        _ -> ""
      end

    socket =
      socket
      |> assign(:agent_id, agent_id)
      |> assign(:current_id, ws)
      |> assign(:workstation_ids, Loopyard.Workstation.list())
      |> assign(:agent, %{id: agent_id, status: :booting})
      |> assign(:agent_ready, false)
      |> assign(:agent_error, nil)
      |> assign(:messages, [])
      |> assign(:streaming_text, "")
      |> assign(:streaming_thinking, "")
      |> assign(:thinking_word, "thinking")
      |> assign(:dockerfile, dockerfile)
      |> assign(:image, Image.status(ws))
      |> assign(:building, false)
      |> assign(:build_output, "")
      |> assign(:build_result, nil)
      |> assign(:console_container, nil)
      |> assign(:console_error, nil)
      |> assign(:term_nonce, 0)
      |> assign(:restarting, false)
      |> assign(:push_token, Loopyard.PushToken.get())
      |> assign(:http_port, LoopyardWeb.Endpoint.config(:http)[:port] || 4000)
      |> assign(:integrations, Integration.all())
      |> assign(:integration_status, Map.new(Integration.all(), &{&1.id, :checking}))
      |> assign_env()

    # Boot only what THIS page uses (off the LV process — these block on
    # container create / CLI boot). The calm hub no longer spins up the
    # workstation agent + console on every view/reconnect — that needless boot
    # (the agent's CLI churns) was part of why the page felt busy.
    socket = if connected?(socket), do: boot_for_action(socket, socket.assigns.live_action, ws), else: socket

    {:ok, socket}
  end

  # Image page: the Dockerfile editor + the agent that edits it, plus a console.
  defp boot_for_action(socket, :image, ws) do
    socket
    |> start_async(:ensure_console, fn -> Container.ensure_up(ws) end)
    |> start_async(:ensure_agent, fn -> Agent.ensure_started() end)
  end

  # Console page: just the shell.
  defp boot_for_action(socket, :console, ws),
    do: start_async(socket, :ensure_console, fn -> Container.ensure_up(ws) end)

  # Hub: only the integration status probes (each execs into the container).
  defp boot_for_action(socket, :show, _ws), do: check_integrations(socket)

  # Env (and anything else): nothing to boot.
  defp boot_for_action(socket, _action, _ws), do: socket

  defp check_integrations(socket) do
    ws = socket.assigns.current_id

    Enum.reduce(socket.assigns.integrations, socket, fn ig, s ->
      start_async(s, {:int_status, ig.id}, fn -> Integration.connected?(ig, ws) end)
    end)
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

  def handle_async({:int_status, id}, {:ok, connected?}, socket) do
    state = if connected?, do: :connected, else: :not_connected
    {:noreply, update(socket, :integration_status, &Map.put(&1, id, state))}
  end

  def handle_async({:int_status, id}, {:exit, _}, socket),
    do: {:noreply, update(socket, :integration_status, &Map.put(&1, id, :not_connected))}

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
    case Env.put(name, value, socket.assigns.current_id) do
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
    Env.delete(key, socket.assigns.current_id)

    {:noreply,
     socket
     |> assign_env()
     |> put_flash(:info, "Removed #{key} — Restart the machine to apply.")}
  end

  def handle_event("restart_machine", _params, socket) do
    # Recreate the workstation container from scratch — for when the shell wedges.
    # Kill the terminal session first so a fresh `docker exec` lands on the new
    # container; the $HOME volume (logins/dotfiles) is untouched.
    ws = socket.assigns.current_id

    socket =
      socket
      |> assign(:restarting, true)
      |> assign(:console_container, nil)
      |> start_async(:restart_machine, fn ->
        Terminal.stop(Container.name(ws))
        Container.down(ws)
        Container.ensure_up(ws)
      end)

    {:noreply, socket}
  end

  # --- Dockerfile editor (manual path) ---

  def handle_event("apply", %{"action" => action, "dockerfile" => df}, socket) do
    case Image.write_dockerfile(df, socket.assigns.current_id) do
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
        |> assign(:image, Image.status(socket.assigns.current_id))
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
     |> assign(:image, Image.status(socket.assigns.current_id))}
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
    ws = socket.assigns.current_id

    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      result =
        Image.build(
          fn data -> Events.Workstation.publish(%Events.Workstation.BuildOutput{data: data}) end,
          ws
        )

      Events.Workstation.publish(%Events.Workstation.BuildDone{result: result})
    end)

    socket
    |> assign(:building, true)
    |> assign(:build_output, "")
    |> assign(:build_result, nil)
  end

  defp assign_env(socket) do
    keys = Env.keys(socket.assigns.current_id)
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
    case Image.read_dockerfile(socket.assigns.current_id) do
      {:ok, d} -> d
      _ -> socket.assigns.dockerfile
    end
  end

  defp cap(s) when byte_size(s) > 64_000,
    do: binary_part(s, byte_size(s) - 64_000, 64_000)

  defp cap(s), do: s

  @impl true
  def render(%{live_action: :console} = assigns), do: console_page(assigns)
  def render(%{live_action: :image} = assigns), do: image_page(assigns)
  def render(%{live_action: :env} = assigns), do: env_page(assigns)
  def render(assigns), do: hub_page(assigns)

  # The hub: who you are, the services to connect, and links to the rest.
  defp hub_page(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[{"Workstations", "/workstations"}, {@current_id, nil}]}
      iex_session={@iex_session}
      max_width={:md}
      flash={@flash}
    >
      <div id="ws-page" phx-hook="WsScroll" class="space-y-8">
        <div class="space-y-3">
          <div class="flex items-baseline justify-between gap-3">
            <h1 class="text-xl font-semibold tracking-tight">{@current_id}</h1>
            <span class="text-[11px] font-mono text-zinc-400 dark:text-zinc-500 truncate">
              {if @image.exists, do: "Image built · " <> @image.size, else: "Image not built"}
            </span>
          </div>

          <%!-- Operating as: who agents inherit + spin up a new identity. --%>
          <div class="flex flex-wrap items-center gap-x-2 gap-y-1.5 text-sm">
            <span class="text-zinc-400 dark:text-zinc-500">Operating as</span>
            <.link
              :for={id <- @workstation_ids}
              href={"/workstations/#{id}"}
              class={[
                "inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 border transition-colors",
                if(id == @current_id,
                  do: "border-sky-500/40 bg-sky-500/10 text-sky-700 dark:text-sky-300 font-medium",
                  else: "border-zinc-200 dark:border-zinc-700 text-zinc-500 dark:text-zinc-400 hover:border-zinc-300 dark:hover:border-zinc-600")
              ]}
            >
              <span class={["w-1.5 h-1.5 rounded-full", if(id == @current_id, do: "bg-sky-500", else: "bg-zinc-300 dark:bg-zinc-600")]}></span>
              {id}
            </.link>
            <form action="/workstations/create" method="post" class="inline-flex items-center gap-1.5">
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <input
                type="text"
                name="ws_id"
                placeholder="new-id"
                pattern="[a-z0-9][a-z0-9-]*"
                title="Lowercase letters, digits, dashes"
                class="w-24 rounded-full border border-dashed border-zinc-300 dark:border-zinc-600 bg-transparent px-2.5 py-0.5 text-sm placeholder:text-zinc-400 focus-ring"
              />
              <button type="submit" class="text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 text-lg leading-none" title="Create workstation">+</button>
            </form>
          </div>
        </div>

        <.section title="Connect your tools" hint="Click in to connect — the default on each is one command you run on your Mac.">
          <.nav_list>
            <.nav_row
              :for={ig <- @integrations}
              navigate={"/workstations/#{@current_id}/#{ig.id}"}
              title={ig.label}
              desc={ig.blurb}
            >
              <:trailing><.status_pill status={@integration_status[ig.id]} /></:trailing>
            </.nav_row>
          </.nav_list>
        </.section>

        <.section title="Configure">
          <.nav_list>
            <.nav_row navigate={"/workstations/#{@current_id}/console"} title="Console" desc="A shell on the workstation — test commands, poke around." />
            <.nav_row navigate={"/workstations/#{@current_id}/image"} title="Image & agent" desc="Edit the Dockerfile, or tell the agent what to install." />
            <.nav_row navigate={"/workstations/#{@current_id}/env"} title="Environment" desc="Transfer creds from your Mac, set env vars, push tokens." />
          </.nav_list>
        </.section>
      </div>
    </.page_shell>
    """
  end

  # --- Console page: a shell on the workstation. ---
  defp console_page(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[{"Workstations", "/workstations"}, {@current_id, "/workstations/#{@current_id}"}, {"Console", nil}]}
      iex_session={@iex_session}
      max_width={:xl}
      flash={@flash}
    >
      <div id="ws-page" phx-hook="WsScroll" class="space-y-3">
        <div class="flex items-center justify-between gap-3">
          <p class="text-sm text-zinc-500 dark:text-zinc-400">
            A shell on <span class="font-medium text-zinc-700 dark:text-zinc-200">{@current_id}</span> — logins persist in $HOME.
          </p>
          <.restart_button restarting={@restarting} />
        </div>
        <div id="ws-console" class="h-[72dvh] rounded-xl border border-zinc-200 dark:border-zinc-700 overflow-hidden p-2 bg-[#18181b]">
          <div
            :if={@console_container}
            id={"terminal-#{@console_container}-#{@term_nonce}"}
            phx-hook="Terminal"
            data-container={@console_container}
            phx-update="ignore"
            class="h-full overflow-hidden"
          >
          </div>
          <div :if={!@console_container && !@console_error} class="h-full flex items-center justify-center text-sm text-zinc-500">
            <span class="inline-flex items-center gap-2">
              <.spinner /> {if @restarting, do: "Restarting the machine…", else: "Starting your console…"}
            </span>
          </div>
          <div :if={@console_error} class="rounded-lg border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/30 p-3 text-sm text-red-600 dark:text-red-400">
            Couldn't start the workstation console: {@console_error}
          </div>
        </div>
      </div>
    </.page_shell>
    """
  end

  # --- Image page: the Dockerfile + the agent that edits it. ---
  defp image_page(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[{"Workstations", "/workstations"}, {@current_id, "/workstations/#{@current_id}"}, {"Image & agent", nil}]}
      iex_session={@iex_session}
      max_width={:xl}
      flash={@flash}
    >
      <div id="ws-page" phx-hook="WsScroll" class="space-y-4">
        <p class="text-sm text-zinc-500 dark:text-zinc-400">
          The image every agent is stamped from. Edit the Dockerfile, or just tell the agent what to install.
        </p>
        <div class="flex flex-col lg:flex-row gap-4 lg:h-[64dvh]">
          <%!-- Dockerfile editor --%>
          <form phx-submit="apply" class="flex flex-col min-h-0 lg:flex-[3] h-[50dvh] lg:h-auto gap-3 rounded-xl border border-zinc-200 dark:border-zinc-700 p-3">
            <div class="flex-none flex items-center gap-2">
              <.button variant={:primary} type="submit" name="action" value="rebuild" disabled={@building}>
                {if @building, do: "Building…", else: "Save & Rebuild"}
              </.button>
              <.button variant={:secondary} type="submit" name="action" value="save" disabled={@building}>
                Save
              </.button>
              <.restart_button restarting={@restarting} class="ml-auto" />
            </div>
            <textarea name="dockerfile" spellcheck="false" autocapitalize="off" autocomplete="off" autocorrect="off" class="flex-1 min-h-0 w-full resize-none font-mono text-xs leading-relaxed rounded-lg border border-zinc-300 dark:border-zinc-700 bg-zinc-950 text-zinc-100 p-3 focus:outline-none focus:ring-2 focus:ring-violet-500/30 focus:border-violet-400">{@dockerfile}</textarea>
          </form>
          <%!-- Agent --%>
          <div id="chat-page" phx-hook="ScrollBottom" class="flex flex-col min-h-0 lg:flex-[2] h-[55dvh] lg:h-auto rounded-xl border border-zinc-200 dark:border-zinc-700 overflow-hidden">
            <div class="flex-none px-4 py-2 border-b border-zinc-200 dark:border-zinc-700 text-xs font-medium text-zinc-500 dark:text-zinc-400">
              Agent — tell it what to install
            </div>
            <div :if={@agent_ready} class="flex-1 flex flex-col min-h-0">
              <.chat_panel messages={@messages} agent={@agent} workspace_id={nil} host="localhost" streaming_text={@streaming_text} streaming_thinking={@streaming_thinking} thinking_word={@thinking_word} />
            </div>
            <div :if={!@agent_ready && !@agent_error} class="flex-1 flex items-center justify-center text-sm text-zinc-500">
              <span class="inline-flex items-center gap-2"><.spinner /> Waking the workstation agent…</span>
            </div>
            <div :if={@agent_error} class="flex-1 flex items-center justify-center p-4 text-sm text-red-600 dark:text-red-400 text-center">
              Couldn't start the workstation agent: {@agent_error}
            </div>
          </div>
        </div>
        <%!-- Build output — fills live whenever a build runs. --%>
        <div :if={@building || @build_output != ""}>
          <div class="flex items-center justify-between mb-1">
            <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500">Build output</div>
            <div :if={@building} class="inline-flex items-center gap-1.5 text-xs text-zinc-500 animate-pulse"><.spinner /> Building…</div>
            <div :if={!@building && @build_result == :ok} class="text-xs font-medium text-emerald-600 dark:text-emerald-400">✓ Built</div>
            <div :if={!@building && match?({:error, _}, @build_result)} class="text-xs font-medium text-red-500">✗ Failed</div>
          </div>
          <pre id="ws-build-output" phx-hook="TailScroll" class="max-h-72 overflow-auto rounded-lg bg-zinc-950 text-zinc-300 text-[11px] leading-relaxed font-mono p-3 whitespace-pre-wrap">{@build_output}</pre>
        </div>
      </div>
    </.page_shell>
    """
  end

  # --- Environment page: transfer creds, set env vars, push tokens. ---
  defp env_page(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[{"Workstations", "/workstations"}, {@current_id, "/workstations/#{@current_id}"}, {"Environment", nil}]}
      iex_session={@iex_session}
      max_width={:md}
      flash={@flash}
    >
      <div id="ws-page" phx-hook="WsScroll" class="space-y-8">
        <.section
          title="Transfer everything from your Mac"
          hint="One command, run where you're logged in — grabs your gh / fly / claude / codex creds and pipes them up. Files apply live; tokens need a Restart."
        >
          <.command_box id="clip-setup" command={"curl -fsS http://localhost:#{@http_port}/workstations/#{@current_id}/setup.sh | sh"} />
        </.section>

        <.section title="Environment variables" hint="Stamped into the console + every agent at boot. Restart to apply.">
          <form phx-submit="add_env" class="flex flex-col sm:flex-row gap-2">
            <input name="name" placeholder="NAME" autocomplete="off" autocapitalize="characters" spellcheck="false" class="sm:w-56 font-mono text-sm rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400" />
            <input name="value" type="password" placeholder="value" autocomplete="off" spellcheck="false" class="flex-1 font-mono text-sm rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400" />
            <.button variant={:secondary} type="submit" class="flex-none">Add</.button>
          </form>
          <ul :if={@other_env_keys != []} class="divide-y divide-zinc-100 dark:divide-zinc-800 rounded-lg border border-zinc-200 dark:border-zinc-800 px-3">
            <li :for={k <- @other_env_keys} class="flex items-center gap-3 py-2">
              <span class="font-mono text-sm text-zinc-700 dark:text-zinc-300">{k}</span>
              <span class="font-mono text-xs text-zinc-400 dark:text-zinc-600 select-none">••••••••</span>
              <button phx-click="delete_env" phx-value-key={k} data-confirm={"Remove #{k}?"} class="ml-auto text-xs text-zinc-400 hover:text-red-500 transition-colors">Remove</button>
            </li>
          </ul>
        </.section>

        <.section
          title="Push a single credential"
          hint="Each tool's page has the easy path. For a custom key or a remote Loopyard, this is the general form (carries your push token):"
        >
          <div id="ws-push" phx-hook="PushCmd" data-token={@push_token} class="relative">
            <pre class="overflow-x-auto rounded-lg bg-zinc-900 dark:bg-zinc-950 text-zinc-100 text-[11px] leading-relaxed font-mono p-3 pr-16 ring-1 ring-zinc-800"><code class="ws-push-cmd">gh auth token | curl -fsS -T - \
  -H "Authorization: Bearer {@push_token}" \
  __ORIGIN__/workstations/{@current_id}/env/GITHUB_TOKEN</code></pre>
            <button type="button" class="ws-push-copy focus-ring absolute top-2 right-2 rounded-md bg-zinc-800 hover:bg-zinc-700 text-zinc-200 px-2 py-1 text-[11px]">Copy</button>
          </div>
          <p class="text-[11px] text-zinc-400 dark:text-zinc-500">
            Swap GITHUB_TOKEN for any key. On this machine you can drop the token entirely. Restart to apply — keep this command secret.
          </p>
        </.section>
      </div>
    </.page_shell>
    """
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
