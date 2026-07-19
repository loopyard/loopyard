defmodule LoopyardWeb.Live.WorkspaceLive.Components.DetailContexts do
  @moduledoc """
  Zone B detail panels for the workspace rail's non-agent selections:
  `service_context/1` (status + URL + every service action) and
  `volume_context/1` (the volume "Info" home + danger-zone delete).

  The agent detail lives in `ContextPanel.context_sections/1`; these two share
  its exact shape (`SideNav.detail_title` + sections) so the rail reads
  identically whatever kind of thing is selected. Split out of
  `Components.Sidebar` for the module-size invariant — the switcher (what's in
  the workspace) stays there; the selected thing's detail lives here.
  """
  use Phoenix.Component

  import LoopyardWeb.Components.SideNav,
    only: [section: 1, info_row: 1, detail_hero: 1, action_bar: 1]

  import LoopyardWeb.Components.Common, only: [control_btn: 1]

  import LoopyardWeb.Components.Sidebar, only: [service_dot: 1, first_host_port: 1]

  import LoopyardWeb.Live.WorkspaceLive.Components.Formatters,
    only: [derive_volume_description: 1]

  alias LoopyardWeb.Live.WorkspaceLive.Components.{ChatStatus, ContextPanel}

  @volume_actions [
    :volume,
    :volume_files_root,
    :volume_file,
    :volume_git,
    :volume_history,
    :git_diff,
    :git_staged_diff,
    :git_commit,
    :git_commit_file
  ]

  @doc """
  The MOBILE detail panel — agent / service / volume — rendered FLAT and inline
  (no sheet, no overlay), so `Nav.toggle_details/0` can swap it for the surface
  content in place and it scrolls with the viewport. Same content as the desktop
  right rail, so the phone reaches every detail the desktop does. Lives in the
  `#mobile-detail` container (hidden until toggled).
  """
  attr :selected_agent, :map, default: nil
  attr :selected_service, :string, default: nil
  attr :selected_volume, :string, default: nil
  attr :service_statuses, :list, default: []
  attr :volumes, :list, default: []
  attr :changes, :map, default: %{staged: [], unstaged: []}
  attr :editing_name, :boolean, default: false
  attr :base_path, :string, required: true
  attr :host, :string, default: nil
  attr :live_action, :atom, default: :index
  attr :streaming_text, :string, default: ""

  def mobile_detail_inline(assigns) do
    # @volume_actions is a MODULE attribute — resolve it here (in the function
    # body) into an assign; inside ~H, `@volume_actions` would read as a
    # (missing) assign and `@live_action in nil` crashes.
    assigns = assign(assigns, :volume_route?, assigns.live_action in @volume_actions)

    ~H"""
    <div class="pb-6">
      <ContextPanel.context_sections
        :if={@selected_agent}
        agent={@selected_agent}
        changes={@changes}
        editing_name={@editing_name}
        base_path={@base_path}
        live_token_est={ChatStatus.token_estimate(@streaming_text)}
      />
      <%!-- nil (not a status-only fallback) so service_context's `svc && …`
           short-circuits — a fallback map has no :ports and would KeyError. --%>
      <.service_context
        :if={@selected_service && @live_action in [:service, :console]}
        svc={Enum.find(@service_statuses, &(&1.name == @selected_service))}
        service_name={@selected_service}
        base_path={@base_path}
        host={@host}
      />
      <.volume_context
        :if={@selected_volume && @volume_route?}
        vol={Enum.find(@volumes, &(&1.name == @selected_volume))}
        volume_name={@selected_volume}
        base_path={@base_path}
        changes={@changes}
      />
    </div>
    """
  end

  # --- Zone B detail: SERVICE ---
  # The selected service's detail: status/URL/connection + EVERY action
  # (Open, Restart, Stop, Console, Open/Close Port, Start). This is where those
  # controls live now — not the center pane's top toolbar. One home for the
  # buttons + LiveView status, consistent with the agent + volume panels.
  attr :svc, :map, default: nil
  attr :service_name, :string, required: true
  attr :base_path, :string, required: true
  attr :host, :string, default: nil

  def service_context(assigns) do
    svc = assigns.svc
    first_port = svc && (Map.get(svc, :host_port) || first_host_port(svc.ports))

    assigns =
      assign(assigns,
        first_port: first_port,
        running?: svc && svc.status == :running,
        exposed?: svc && Map.get(svc, :exposed, false),
        container_port: svc && Map.get(svc, :container_port)
      )

    ~H"""
    <%!-- STICKY HERO: service name + live status (Running/Stopped…) flush-right,
         port · exposure inline. --%>
    <.detail_hero
      eyebrow="Service"
      name={@service_name}
      dot={@svc && service_dot(@svc)}
      status={svc_status_label(@svc)}
      status_class={svc_status_pill(@svc)}
    >
      <:facts :if={@first_port}>
        :{@first_port} · {if @exposed?, do: "Network", else: "Local only"}
      </:facts>
    </.detail_hero>

    <%!-- What the service IS — image + type. Always present (every service has an
         image), so it also gives a portless service real middle content. --%>
    <.section :if={@svc && (svc_image(@svc) || svc_type(@svc))} label="Service">
      <.info_row
        :if={svc_image(@svc)}
        label="Image"
        value={svc_image(@svc)}
        monospace
        class="text-zinc-700 dark:text-zinc-300"
      />
      <.info_row :if={svc_type(@svc)} label="Kind" value={svc_kind_label(svc_type(@svc))} />
    </.section>

    <%!-- Connection details only when there ARE any (a port or container port).
         A portless service (e.g. `work`) has none — status lives in the hero —
         so we skip the section entirely rather than render an empty header. --%>
    <.section :if={@first_port || @container_port} label="Connection">
      <div
        :if={@first_port}
        class="flex items-center justify-between gap-3 px-2 min-h-7 md:min-h-6 text-sm"
      >
        <span class="text-zinc-500 dark:text-zinc-400 flex-none">URL</span>
        <a
          href={"http://#{@host}:#{@first_port}"}
          target="_blank"
          rel="noopener"
          class="truncate font-mono text-violet-500 hover:text-violet-400 transition-colors"
        >
          {@host}:{@first_port}
        </a>
      </div>
      <.info_row
        :if={@container_port}
        label="Container port"
        value={@container_port}
        monospace
      />
      <.info_row
        :if={@first_port}
        label="Exposure"
        value={if @exposed?, do: "Network", else: "Local only"}
      />
    </.section>

    <%!-- STICKY FOOTER: every service action, one consistent home. --%>
    <.action_bar>
      <:main>
        <%!-- PRIMARY: open the running app, expose a port, or start it. --%>
        <.control_btn
          :if={@first_port}
          variant={:primary}
          href={"http://#{@host}:#{@first_port}"}
          target="_blank"
          rel="noopener"
          class="w-full justify-center"
        >
          Open ↗
        </.control_btn>
        <.control_btn
          :if={!@first_port && !@exposed? && @container_port && @running?}
          variant={:primary}
          phx-click="toggle_port_exposure"
          phx-value-service={@service_name}
          phx-value-container_port={@container_port}
          phx-value-expose="true"
          class="w-full justify-center"
        >
          Open Port
        </.control_btn>
        <.control_btn
          :if={!@running?}
          variant={:primary}
          phx-click="start_service"
          phx-value-service_name={@service_name}
          class="w-full justify-center"
        >
          Start
        </.control_btn>

        <%!-- SECONDARY: full-width single column on mobile (big tap targets),
             2-up grid on the desktop rail where space is tight. --%>
        <div :if={@running?} class="grid grid-cols-1 md:grid-cols-2 gap-1.5">
          <.control_btn
            phx-click="restart_service"
            phx-value-service_name={@service_name}
            class="w-full justify-center"
          >
            Restart
          </.control_btn>
          <.control_btn
            phx-click="stop_service"
            phx-value-service_name={@service_name}
            class="w-full justify-center"
          >
            Stop
          </.control_btn>
          <.control_btn
            patch={"#{@base_path}/services/#{@service_name}/console"}
            class="w-full justify-center"
          >
            Console
          </.control_btn>
          <.control_btn
            :if={@exposed? && @container_port}
            phx-click="toggle_port_exposure"
            phx-value-service={@service_name}
            phx-value-container_port={@container_port}
            phx-value-expose="false"
            class="w-full justify-center"
          >
            Close Port
          </.control_btn>
        </div>
      </:main>
    </.action_bar>
    """
  end

  # Pill classes (bg + text) for the hero status badge — mirrors service_dot/1.
  defp svc_status_pill(%{status: :running}),
    do: "bg-emerald-500/15 text-emerald-700 dark:text-emerald-400"

  defp svc_status_pill(%{status: :crashed}), do: "bg-red-500/15 text-red-600 dark:text-red-400"

  defp svc_status_pill(%{status: :starting}),
    do: "bg-blue-500/15 text-blue-700 dark:text-blue-400"

  defp svc_status_pill(_), do: "bg-zinc-500/15 text-zinc-600 dark:text-zinc-300"

  # Safe field access — @svc is a %Service{} struct (no Access protocol), so
  # `svc[:image]` would crash at render; Map.get works on struct AND plain map.
  defp svc_image(svc), do: Map.get(svc, :image)
  defp svc_type(svc), do: Map.get(svc, :type)

  # Human label for a service's inferred kind.
  defp svc_kind_label(:stock), do: "Stock service"
  defp svc_kind_label(:process), do: "App process"
  defp svc_kind_label(:code), do: "Code volume"
  defp svc_kind_label(other), do: other |> to_string() |> String.capitalize()

  # Human status word for a service, and its text color — mirrors service_dot/1.
  defp svc_status_label(nil), do: "—"
  defp svc_status_label(%{status: :running}), do: "Running"
  defp svc_status_label(%{status: :starting}), do: "Starting…"
  defp svc_status_label(%{status: :crashed}), do: "Crashed"
  defp svc_status_label(%{status: :stopped}), do: "Stopped"
  defp svc_status_label(%{status: s}), do: s |> to_string() |> String.capitalize()

  # --- Zone B detail: VOLUME (the "Info" home) ---
  # Files / Changes / History are switcher items; what remains here is the
  # volume's METADATA — the old Info tab, relocated: desktop right rail +
  # mobile pull-up sheet ("volume-context"). Plus the danger-zone delete for
  # non-code volumes, which lived on that tab too.
  attr :vol, :map, default: nil
  attr :volume_name, :string, required: true
  attr :base_path, :string, required: true
  attr :changes, :map, default: %{staged: [], unstaged: []}

  def volume_context(assigns) do
    name = assigns.volume_name || (assigns.vol && assigns.vol.name)
    vol = assigns.vol
    code? = String.contains?(name || "", "code")

    vol_type =
      cond do
        vol && vol[:type] -> vol.type
        code? -> :code
        String.contains?(name || "", "cache") -> :cache
        true -> :data
      end

    assigns =
      assign(assigns,
        description:
          (vol && (vol[:description] || derive_volume_description(vol.name))) ||
            derive_volume_description(name),
        code?: code?,
        vol_type: vol_type,
        changes_count: changes_count(assigns.changes)
      )

    ~H"""
    <%!-- STICKY HERO: volume name + type · size inline. --%>
    <.detail_hero eyebrow="Volume" name={@description} dot="bg-blue-400">
      <:facts>
        {@vol_type}{if @vol && @vol[:size], do: " · #{@vol.size}"}
      </:facts>
    </.detail_hero>

    <.section label="Info">
      <.info_row label="Type" value={@vol_type} />
      <.info_row :if={@vol && @vol[:size]} label="Size" value={@vol.size} monospace />
      <.info_row
        :if={@vol && @vol[:service] && @vol.service != "workspace"}
        label="Service"
        value={@vol.service}
      />
      <.info_row :if={@code?} label="Changed files" value={@changes_count} />
      <.info_row
        label="Name"
        value={@volume_name}
        monospace
        class="font-mono text-zinc-500 dark:text-zinc-400 text-xs"
      />
      <p :if={@code?} class="px-2 pt-1 text-xs text-zinc-500 dark:text-zinc-400">
        The main project source volume — the codebase agents and services share.
      </p>
    </.section>

    <%!-- STICKY FOOTER: destructive delete (non-code volumes only), set apart.
         Code volume → no footer at all. --%>
    <.action_bar>
      <:danger :if={!@code?}>
        <.control_btn
          variant={:danger}
          phx-click="delete_volume"
          phx-value-volume_name={@volume_name}
          data-confirm="Delete this volume? All data will be lost."
          class="w-full justify-center"
        >
          Delete volume
        </.control_btn>
      </:danger>
    </.action_bar>
    """
  end

  # Changed-file count for a working tree (staged + unstaged, deduped by path).
  # Duplicated from Components.Sidebar (tiny, pure) — both modules need it.
  defp changes_count(%{} = changes) do
    ((Map.get(changes, :staged) || []) ++ (Map.get(changes, :unstaged) || []))
    |> Enum.uniq_by(& &1.path)
    |> length()
  end

  defp changes_count(_), do: 0
end
