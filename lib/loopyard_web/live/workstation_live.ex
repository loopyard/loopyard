defmodule LoopyardWeb.WorkstationLive do
  @moduledoc """
  The **Workstation** page — see/edit the Dockerfile for the base image every
  agent is stamped from, and rebuild it. Deliberately phone-first: it's a text
  box and a Rebuild button, so you can tweak your machine from the road.

  Scope (MVP): the *image* half of a workstation (tools/system packages). Logins
  and language versions live in the `$HOME` volume — a later piece. See
  plans/workstations.md.
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  alias Loopyard.Workstation.Image

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket),
        do: subscribe_iex(socket),
        else: assign(socket, :iex_session, %{level: nil})

    dockerfile =
      case Image.read_dockerfile() do
        {:ok, d} -> d
        _ -> ""
      end

    {:ok,
     socket
     |> assign(:dockerfile, dockerfile)
     |> assign(:image, Image.status())
     |> assign(:building, false)
     |> assign(:build_output, "")
     |> assign(:build_result, nil)}
  end

  @impl true
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

  @impl true
  def handle_info({:build_chunk, data}, socket) do
    combined = socket.assigns.build_output <> data

    # Cap the buffer so a long build doesn't grow assigns unboundedly.
    capped =
      if byte_size(combined) > 64_000,
        do: binary_part(combined, byte_size(combined) - 64_000, 64_000),
        else: combined

    {:noreply, socket |> assign(:build_output, capped) |> push_event("ws_build_scroll", %{})}
  end

  def handle_info({:build_done, result}, socket) do
    {:noreply,
     socket
     |> assign(:building, false)
     |> assign(:build_result, result)
     |> assign(:image, Image.status())
     |> push_event("ws_build_scroll", %{})}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp start_build(socket) do
    lv = self()

    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      result = Image.build(fn data -> send(lv, {:build_chunk, data}) end)
      send(lv, {:build_done, result})
    end)

    socket
    |> assign(:building, true)
    |> assign(:build_output, "")
    |> assign(:build_result, nil)
  end

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
        <div>
          <h2 class="text-lg md:text-xl font-semibold">Workstation</h2>
          <p class="text-sm text-zinc-500 dark:text-zinc-400 mt-1">
            The base image every agent is stamped from — your tools, your machine. Edit the
            Dockerfile and rebuild; new agents pick it up. (Your logins and language versions
            live in <span class="font-mono">$HOME</span>, not here.)
          </p>
        </div>

        <div class="rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 flex items-center justify-between gap-3">
          <div class="min-w-0">
            <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500">
              Image
            </div>
            <div class="font-mono text-sm text-zinc-700 dark:text-zinc-300 truncate">
              {Image.tag()}
            </div>
            <div class="text-xs text-zinc-400 dark:text-zinc-500 mt-0.5">
              <%= if @image.exists do %>
                {@image.size} · built
              <% else %>
                not built yet — hit Rebuild
              <% end %>
            </div>
          </div>
          <div
            :if={@building}
            class="inline-flex items-center gap-1.5 text-xs text-zinc-500 animate-pulse flex-none"
          >
            <.spinner /> Building…
          </div>
          <div
            :if={!@building && @build_result == :ok}
            class="text-xs font-medium text-emerald-600 dark:text-emerald-400 flex-none"
          >
            ✓ Built
          </div>
          <div
            :if={!@building && match?({:error, _}, @build_result)}
            class="text-xs font-medium text-red-500 flex-none"
          >
            ✗ Failed
          </div>
        </div>

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

        <div :if={@building || @build_output != ""}>
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-1">
            Build output
          </div>
          <pre
            id="ws-build-output"
            phx-hook="TailScroll"
            class="max-h-96 overflow-auto rounded-lg bg-zinc-950 text-zinc-300 text-[11px] leading-relaxed font-mono p-3 whitespace-pre-wrap"
          >{@build_output}</pre>
        </div>
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
