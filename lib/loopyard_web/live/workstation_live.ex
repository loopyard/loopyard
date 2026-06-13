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
  alias Loopyard.Workstation.{Agent, Container, Image}

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
      |> assign(:open_url, nil)

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

  def handle_event("dismiss_open_url", _params, socket),
    do: {:noreply, assign(socket, :open_url, nil)}

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

  @impl Events.Workstation.Subscriber
  def on_open_url(%Events.Workstation.OpenUrl{url: url}, socket),
    do: {:noreply, assign(socket, :open_url, url)}

  # --- handle_info dispatch (struct -> on_* callback; no macro, per Move #3) ---

  @impl true
  def handle_info(%Events.ChatAgentMessage.Message{} = e, socket), do: on_message(e, socket)
  def handle_info(%Events.ChatAgentMessage.TextDelta{} = e, socket), do: on_text_delta(e, socket)

  def handle_info(%Events.ChatAgentMessage.StreamOutput{} = e, socket),
    do: on_stream_output(e, socket)

  def handle_info(%Events.Workstation.BuildOutput{} = e, socket), do: on_build_output(e, socket)
  def handle_info(%Events.Workstation.BuildDone{} = e, socket), do: on_build_done(e, socket)
  def handle_info(%Events.Workstation.OpenUrl{} = e, socket), do: on_open_url(e, socket)
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
      max_width={:lg}
      flash={@flash}
    >
      <div class="space-y-6">
        <%!-- One-tap login: a container's `xdg-open` routed a URL here. Tapping
             the anchor is a user gesture, so it opens reliably (even on mobile). --%>
        <div
          :if={@open_url}
          class="sticky top-2 z-20 flex items-center gap-3 rounded-xl border border-violet-300 dark:border-violet-700 bg-violet-50 dark:bg-violet-950/40 px-4 py-3 shadow-sm"
        >
          <span class="text-lg flex-none">🔗</span>
          <div class="min-w-0 flex-1">
            <div class="text-sm font-medium text-zinc-800 dark:text-zinc-100">
              A login wants to open a page
            </div>
            <div class="text-xs text-zinc-500 dark:text-zinc-400 truncate font-mono">{@open_url}</div>
          </div>
          <a
            href={@open_url}
            target="_blank"
            rel="noopener"
            phx-click="dismiss_open_url"
            class="focus-ring flex-none inline-flex items-center rounded-lg bg-violet-600 hover:bg-violet-700 text-white px-4 py-2 text-sm font-semibold transition-colors"
          >
            Open
          </a>
          <button
            phx-click="dismiss_open_url"
            aria-label="Dismiss"
            class="flex-none text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-200 text-lg leading-none px-1"
          >
            ×
          </button>
        </div>

        <div>
          <h2 class="text-lg md:text-xl font-semibold">Workstation</h2>
          <p class="text-sm text-zinc-500 dark:text-zinc-400 mt-1">
            Your machine. Tell the agent what to install and it edits the image + rebuilds —
            or log into your tools in the console, or hand-edit the Dockerfile yourself.
          </p>
        </div>

        <%!-- Chat with the workstation agent — the primary way to configure the box. --%>
        <div id="chat-page" phx-hook="ScrollBottom" class="rounded-xl border border-zinc-200 dark:border-zinc-700 overflow-hidden">
          <div class="h-[58vh] min-h-[360px] flex flex-col">
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
            class="max-h-96 overflow-auto rounded-lg bg-zinc-950 text-zinc-300 text-[11px] leading-relaxed font-mono p-3 whitespace-pre-wrap"
          >{@build_output}</pre>
        </div>

        <%!-- Console: the shell where you log into your tools. --%>
        <details open class="rounded-xl border border-zinc-200 dark:border-zinc-700 group">
          <summary class="cursor-pointer select-none px-4 py-3 flex items-center justify-between">
            <span class="text-sm font-medium">Console</span>
            <span class="text-[11px] text-zinc-400 dark:text-zinc-500">
              logins persist in $HOME · gh auth login · claude login · fly auth login
            </span>
          </summary>
          <div class="px-4 pb-4">
            <div
              :if={@console_container}
              id={"terminal-#{@console_container}"}
              phx-hook="Terminal"
              data-container={@console_container}
              phx-update="ignore"
              class="h-[48vh] min-h-[300px] bg-[#18181b] rounded-lg p-2 overflow-hidden"
            >
            </div>
            <div
              :if={!@console_container && !@console_error}
              class="h-[48vh] min-h-[300px] bg-[#18181b] rounded-lg flex items-center justify-center text-sm text-zinc-500"
            >
              <span class="inline-flex items-center gap-2"><.spinner /> Starting your console…</span>
            </div>
            <div
              :if={@console_error}
              class="rounded-lg border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/30 p-3 text-sm text-red-600 dark:text-red-400"
            >
              Couldn't start the workstation console: {@console_error}
            </div>
          </div>
        </details>

        <%!-- Image + Dockerfile: the agent edits this, but you can too. --%>
        <details class="rounded-xl border border-zinc-200 dark:border-zinc-700">
          <summary class="cursor-pointer select-none px-4 py-3 flex items-center justify-between gap-3">
            <span class="text-sm font-medium">Image &amp; Dockerfile</span>
            <span class="text-[11px] font-mono text-zinc-400 dark:text-zinc-500 truncate">
              {Image.tag()} ·
              <%= if @image.exists do %>
                {@image.size}
              <% else %>
                not built
              <% end %>
            </span>
          </summary>
          <div class="px-4 pb-4">
            <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-2">
              Tools/packages baked into every agent. Ask the agent above to change it, or edit directly:
            </p>
            <form phx-submit="apply" class="space-y-3">
              <div class="flex items-center gap-2">
                <button
                  type="submit"
                  name="action"
                  value="rebuild"
                  disabled={@building}
                  class="focus-ring inline-flex items-center justify-center gap-1.5 rounded-lg bg-violet-600 hover:bg-violet-700 disabled:opacity-60 text-white px-4 py-2.5 text-sm font-semibold transition-colors"
                >
                  {if @building, do: "Building…", else: "Save & Rebuild"}
                </button>
                <button
                  type="submit"
                  name="action"
                  value="save"
                  disabled={@building}
                  class="focus-ring inline-flex items-center rounded-lg border border-zinc-300 dark:border-zinc-600 px-4 py-2.5 text-sm font-medium text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-60 transition-colors"
                >
                  Save
                </button>
              </div>
              <textarea
                name="dockerfile"
                rows="22"
                spellcheck="false"
                autocapitalize="off"
                autocomplete="off"
                autocorrect="off"
                class="w-full font-mono text-xs leading-relaxed rounded-lg border border-zinc-300 dark:border-zinc-700 bg-zinc-950 text-zinc-100 p-3
                       focus:outline-none focus:ring-2 focus:ring-violet-500/30 focus:border-violet-400"
              >{@dockerfile}</textarea>
            </form>
          </div>
        </details>
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
