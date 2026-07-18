defmodule LoopyardWeb.Live.WorkspaceLive.Components.ChatNav do
  @moduledoc """
  The workspace section-switcher model: which category (Agents / Services /
  Files) the current route belongs to, each category's items + hrefs, the
  currently-selected item, and the small display helpers they share. Pure
  functions over the chat header's assigns — no markup. Split out of
  `Components.Chat` for the module-size invariant; Chat renders, this decides
  what there is to render.
  """

  import LoopyardWeb.Components.Sidebar,
    only: [status_dot: 1, agent_display_status: 1]

  # Title for the full-screen item switcher, by active category.
  def section_title(:services), do: "Switch service"
  def section_title(:volumes), do: "Files"
  def section_title(_), do: "Switch agent"

  # The section tabs for Row 2 — Agents is always present, Services / Repo only
  # when the workspace actually has them. Empty on the "new agent" route (nothing
  # to switch between yet). `Nav.segmented` hides itself when the list is empty.
  def section_tabs(%{live_action: :new}), do: []

  def section_tabs(a) do
    [%{label: "Agents", active?: a.active == :agents, patch: a.agents_href}] ++
      if(a.service_statuses != [],
        do: [%{label: "Services", active?: a.active == :services, patch: a.services_href}],
        else: []
      ) ++
      if(a.volumes != [],
        # "Files" (not "Repo" — too narrow): this surface is heading toward the
        # code's current state + changes + the files in the container, not just a
        # git repo. See the Files-unification follow-up.
        do: [%{label: "Files", active?: a.active == :volumes, patch: a.volumes_href}],
        else: []
      )
  end

  # The workspace's first reachable (network-exposed) app port from the global
  # tree — `%{port, url}` or nil. Used for the phone header's open-app button.
  def current_ws_port(nil, _ws_id), do: nil

  def current_ws_port(tree, ws_id) do
    tree
    |> Enum.flat_map(& &1.workspaces)
    |> Enum.find(&(&1.id == ws_id))
    |> case do
      %{ports: [p | _]} -> p
      _ -> nil
    end
  end

  # Which workspace category the current route belongs to — drives the active
  # pill. Every agent sub-view (chat/container/info/context) is "Agents"; every
  # service/console route is "Services"; every volume/git/sync route is "Volumes".
  def active_category(action)
      when action in [:service, :services, :console],
      do: :services

  def active_category(action)
      when action in [
             :volume,
             :volume_files_root,
             :volume_file,
             :volume_git,
             :volume_history,
             :git_diff,
             :git_staged_diff,
             :git_commit,
             :git_commit_file,
             :sync
           ],
      do: :volumes

  def active_category(_), do: :agents

  # Content-first target for a category tab: the last item you had open there,
  # else that category's list (or its first item when there's no list route).
  def category_href(:agents, %{nav_agent_id: id, base_path: bp}) when is_binary(id),
    do: "#{bp}/agents/#{id}"

  def category_href(:agents, %{agents: [a | _], base_path: bp}), do: "#{bp}/agents/#{a.id}"

  def category_href(:agents, %{base_path: bp}), do: bp

  def category_href(:services, %{nav_service: s, base_path: bp}) when is_binary(s),
    do: "#{bp}/services/#{s}"

  def category_href(:services, %{service_statuses: [s | _], base_path: bp}),
    do: "#{bp}/services/#{s.name}"

  def category_href(:services, %{base_path: bp}), do: "#{bp}/services"

  def category_href(:volumes, %{nav_volume: v, base_path: bp}) when is_binary(v),
    do: "#{bp}/volumes/#{v}"

  def category_href(:volumes, %{volumes: [vol | _], base_path: bp}),
    do: "#{bp}/volumes/#{vol_name(vol)}"

  def category_href(:volumes, %{base_path: bp}), do: bp

  defp vol_name(vol), do: Map.get(vol, :name) || Map.get(vol, "name")

  # Items of the active category for the switcher, each with a label, route,
  # status dot, one-word detail, and whether it's the one currently open.
  def category_items(%{active: :agents, agents: agents, base_path: bp, nav_agent_id: cur}) do
    Enum.map(agents, fn a ->
      %{
        label: Map.get(a, :name) || a.id,
        href: "#{bp}/agents/#{a.id}",
        active?: a.id == cur,
        dot: status_dot(a.status),
        detail: status_word(a)
      }
    end)
  end

  def category_items(%{
        active: :services,
        service_statuses: svcs,
        base_path: bp,
        nav_service: cur
      }) do
    Enum.map(svcs, fn s ->
      %{
        label: s.name,
        href: "#{bp}/services/#{s.name}",
        active?: s.name == cur,
        dot: svc_dot(s),
        detail: svc_word(s)
      }
    end)
  end

  def category_items(%{active: :volumes, volumes: vols, base_path: bp, nav_volume: cur} = a) do
    action = a[:live_action]

    Enum.flat_map(vols, fn v ->
      n = vol_name(v)

      if String.contains?(n || "", "code") do
        # The code volume expands into the standard switcher items — Files /
        # Changes / History — mirroring the desktop rail (no tab bar in the view).
        [
          %{
            label: "Files",
            href: "#{bp}/volumes/#{n}/files",
            active?: n == cur && action in [:volume, :volume_files_root, :volume_file],
            dot: "bg-blue-400",
            detail: nil
          },
          %{
            label: "Changes",
            href: "#{bp}/volumes/#{n}/git",
            active?: n == cur && action in [:volume_git, :git_diff, :git_staged_diff],
            dot: "bg-amber-400",
            detail: nil
          },
          %{
            label: "History",
            href: "#{bp}/volumes/#{n}/history",
            active?: n == cur && action in [:volume_history, :git_commit, :git_commit_file],
            dot: "bg-zinc-400",
            detail: nil
          }
        ]
      else
        [
          %{
            label: vol_label(n),
            href: "#{bp}/volumes/#{n}/files",
            active?: n == cur,
            dot: "bg-blue-400",
            detail: nil
          }
        ]
      end
    end)
  end

  def category_items(_), do: []

  # The single currently-selected item of the active category, for Row 2. nil →
  # nothing is selected in this category yet (e.g. on a list), so Row 2 hides.
  def current_item(%{active: :agents, agents: agents, nav_agent_id: id}) do
    case Enum.find(agents, &(&1.id == id)) do
      nil ->
        nil

      ag ->
        # No changed-files badge here — a bare "● 25" in the header read as a
        # mystery. The agent's live status (Ready / Working / Thinking) is the
        # useful signal; the changes count lives in the right-rail "Changes".
        %{
          label: Map.get(ag, :name) || ag.id,
          dot: status_dot(ag.status),
          detail: status_word(ag),
          tone: status_tone(ag),
          badge: nil
        }
    end
  end

  def current_item(%{active: :services, service_statuses: svcs, nav_service: name}) do
    case Enum.find(svcs, &(&1.name == name)) do
      nil ->
        nil

      s ->
        %{
          label: s.name,
          dot: svc_dot(s),
          detail: svc_word(s),
          tone: "text-zinc-400 dark:text-zinc-500",
          badge: nil
        }
    end
  end

  def current_item(%{active: :volumes, volumes: vols, nav_volume: name}) do
    case Enum.find(vols, &(vol_name(&1) == name)) do
      nil ->
        nil

      v ->
        %{label: vol_label(vol_name(v)), dot: "bg-blue-400", detail: nil, tone: nil, badge: nil}
    end
  end

  def current_item(_), do: nil

  # A code-volume name like "loopyard-abcd-code" → its meaningful tail ("code").
  defp vol_label(name) when is_binary(name), do: name |> String.split("-") |> List.last()
  defp vol_label(name), do: to_string(name)

  defp svc_dot(%{status: :running}), do: "bg-emerald-500"
  defp svc_dot(%{status: s}) when s in [:restarting, :starting], do: "bg-amber-500 animate-pulse"
  defp svc_dot(_), do: "bg-zinc-400"

  defp svc_word(%{status: s}) when is_atom(s) and not is_nil(s),
    do: s |> to_string() |> String.capitalize()

  defp svc_word(_), do: nil

  # Plain-language status word + tone for the folded mobile Info summary.
  def status_word(agent) do
    case agent_display_status(agent) do
      :thinking -> "Working"
      :idle -> "Ready"
      s when s in [:sleeping, :crashed] -> "Asleep"
      other -> other |> to_string() |> String.capitalize()
    end
  end

  def status_tone(agent) do
    case agent_display_status(agent) do
      :thinking -> "text-violet-600 dark:text-violet-400"
      :idle -> "text-emerald-600 dark:text-emerald-400"
      _ -> "text-zinc-500 dark:text-zinc-400"
    end
  end
end
