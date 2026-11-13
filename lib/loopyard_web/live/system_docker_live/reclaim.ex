defmodule LoopyardWeb.SystemDockerLive.Reclaim do
  @moduledoc """
  "Free up space" on `/system/docker`: what the automatic cleanup did, and the
  groups it will not touch, each with its warning and its remove buttons
  (`Loopyard.GC.Review`).

  The page is how you get relief from a phone when the Docker disk fills, so:

    * the survey (`docker system df -v`, seconds on a busy daemon) loads
      async, and a removal runs async with a "Removing…" line — the page
      never hangs on Docker;
    * a click names a GROUP (and, for one row, a name). The server RE-SURVEYS
      and removes only what the fresh survey still lists in that group under
      that name — never a name taken on trust from the client;
    * the result says what went and what Docker refused (still in use).

  These are LiveView events for a human at the page. They are not agent tools
  and nothing in the MCP bridge reaches them.
  """
  use Phoenix.Component

  alias Loopyard.Docker.Disk
  alias Loopyard.GC
  alias LoopyardWeb.Components.StreamCard

  @shown 6

  @groups %{
    stopped_containers: %{
      title: "Stopped containers",
      warning:
        "Containers that are not Loopyard's and are not running. Their volumes are kept. " <>
          "Removing them also frees the images only they were holding.",
      bulk: "Remove all stopped containers",
      confirm: "Remove every stopped container listed here? Their volumes are kept."
    },
    unused_images: %{
      title: "Unused images",
      warning:
        "Images no container uses. They are pulled or rebuilt when next needed, which costs " <>
          "time, not data. Each size is what that image holds alone; shared layers free up " <>
          "when the last image using them goes.",
      bulk: "Remove all unused images",
      confirm: "Remove every unused image listed here? They are pulled or rebuilt when needed."
    },
    unknown: %{
      title: "Leftovers this server doesn't recognise",
      warning:
        "Named like Loopyard's, but for a workspace that is not registered here: usually a " <>
          "deleted workspace or an old test run. If another Loopyard uses this Docker, they " <>
          "may be ITS workspaces. A code volume holds uncommitted work. This cannot be undone.",
      bulk: "Remove all of these leftovers",
      confirm:
        "Remove every leftover listed here, code volumes included? If another Loopyard " <>
          "shares this Docker these may be its workspaces. This cannot be undone."
    },
    other_volumes: %{
      title: "Other unattached volumes",
      warning:
        "Volumes no container mounts, from other tools. This is data and cannot be undone, " <>
          "so they go one at a time.",
      bulk: nil,
      confirm: nil
    }
  }

  @doc "One survey: the automatic tier's status and the reviewable groups."
  def load do
    case survey() do
      {:ok, %{auto: auto, groups: groups}} ->
        {:ok, %{auto: auto, groups: groups, status: GC.Auto.status(), disk: disk()}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Injection seams for the LiveView tests (the default suite has no daemon).
  defp survey, do: Application.get_env(:loopyard, :reclaim_survey_fun, &GC.Runner.survey/0).()

  defp do_remove(rows),
    do: Application.get_env(:loopyard, :reclaim_remove_fun, &GC.Runner.remove/1).(rows)

  defp disk do
    Loopyard.Docker.DiskMonitor.observation()
  catch
    :exit, _ -> nil
  end

  @doc """
  Remove from a fresh survey: the whole `group`, or just `name` in it.
  Returns `{:ok, %{removed: n, freed: bytes, failed: [reason]}} | {:error, reason}`.
  """
  def remove(group, name \\ nil) when is_atom(group) do
    with true <- Map.has_key?(@groups, group) or {:error, "unknown group"},
         true <- not is_nil(name) or not is_nil(@groups[group].bulk) or {:error, "one at a time"},
         {:ok, %{groups: groups}} <- survey() do
      rows = Map.get(groups, group, [])
      rows = if name, do: Enum.filter(rows, &(&1.name == name)), else: rows
      %{removed: removed, failed: failed} = do_remove(GC.Review.removal_order(rows))

      {:ok,
       %{
         removed: length(removed),
         freed: GC.Review.total(removed),
         failed: Enum.map(failed, fn {c, why} -> "#{c.name}: #{first_line(why)}" end)
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "nothing to remove"}
    end
  end

  @doc "Remove the automatic tier's candidates now, without the wait (a human asked)."
  def remove_auto do
    with {:ok, %{auto: auto}} <- survey() do
      %{removed: removed, failed: failed} = do_remove(auto)

      {:ok,
       %{
         removed: length(removed),
         freed: GC.total(removed),
         failed: Enum.map(failed, fn {c, why} -> "#{c.name}: #{first_line(why)}" end)
       }}
    end
  end

  @doc "The group atom for a client string, or nil."
  def group_key(key) when is_binary(key),
    do: Enum.find(GC.Review.group_keys(), &(Atom.to_string(&1) == key))

  def group_key(_), do: nil

  @doc "The flash line for a removal's result."
  def result_line(%{removed: 0, failed: []}), do: "Nothing to remove."

  def result_line(%{removed: n, freed: freed, failed: failed}) do
    kept =
      case failed do
        [] -> ""
        [one] -> " Docker kept 1 (#{one})."
        many -> " Docker kept #{length(many)} that are still in use."
      end

    "Removed #{n} (#{Disk.human_bytes(freed)})." <> kept
  end

  defp first_line(why),
    do: why |> to_string() |> String.split("\n") |> hd() |> String.slice(0, 120)

  # ── the section ────────────────────────────────────────────────────────

  attr :reclaim, :any, required: true, doc: "AsyncResult of load/0"
  attr :busy, :string, default: nil, doc: "what is being removed right now"

  def section(assigns) do
    ~H"""
    <section id="reclaim">
      <h2 class="text-body font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        Free up space
      </h2>

      <p
        :if={@busy}
        id="reclaim-busy"
        class="mb-3 text-body font-medium text-violet-700 dark:text-violet-300"
        role="status"
      >
        Removing {@busy}…
      </p>

      <%= cond do %>
        <% @reclaim.loading && is_nil(@reclaim.result) -> %>
          <p class="text-body text-zinc-500 dark:text-zinc-400" role="status">
            Measuring what Docker is holding…
          </p>
        <% match?({:error, _}, @reclaim.result) or @reclaim.failed -> %>
          <p class="text-body text-zinc-500 dark:text-zinc-400">
            Couldn't read Docker's usage right now. The daemon may be down or the disk
            completely full.
          </p>
        <% true -> %>
          <% {:ok, data} = @reclaim.result %>
          <.automatic status={data.status} auto={data.auto} disk={data.disk} busy={@busy} />
          <.group
            :for={key <- GC.Review.group_keys()}
            key={key}
            rows={Map.get(data.groups, key, [])}
            busy={@busy}
          />
      <% end %>
    </section>
    """
  end

  attr :status, :map, required: true
  attr :auto, :list, required: true
  attr :disk, :any, default: nil
  attr :busy, :string, default: nil

  defp automatic(assigns) do
    ~H"""
    <div class="mb-6 border border-zinc-200 dark:border-zinc-700/80 p-4">
      <p class="text-body font-semibold text-zinc-900 dark:text-zinc-50">Automatic cleanup</p>
      <p class="text-body text-zinc-600 dark:text-zinc-300">
        {disk_line(@disk)} Loopyard removes its own unused leftovers by itself: test volumes,
        finished sign-in containers and superseded base images, hourly and whenever the disk
        runs low.
      </p>
      <p class="text-body text-zinc-600 dark:text-zinc-300">{auto_line(@status, @auto)}</p>
      <button
        :if={@auto != []}
        type="button"
        phx-click="reclaim_auto"
        disabled={!is_nil(@busy)}
        class={["mt-3", StreamCard.action_class()]}
      >
        Run it now
      </button>
    </div>
    """
  end

  attr :key, :atom, required: true
  attr :rows, :list, required: true
  attr :busy, :string, default: nil

  defp group(assigns) do
    assigns =
      assigns
      |> assign(:meta, Map.fetch!(@groups, assigns.key))
      |> assign(:shown, Enum.take(assigns.rows, @shown))
      |> assign(:more, max(length(assigns.rows) - @shown, 0))
      |> assign(:total, GC.Review.total(assigns.rows))

    ~H"""
    <div :if={@rows != []} id={"reclaim-#{@key}"} class="mb-6">
      <div class="flex flex-wrap items-baseline gap-x-3">
        <p class="text-body font-semibold text-zinc-900 dark:text-zinc-50">{@meta.title}</p>
        <p class="text-body tabular-nums text-zinc-500 dark:text-zinc-400">
          {length(@rows)} · {Disk.human_bytes(@total)}
        </p>
      </div>
      <p class="text-body text-zinc-600 dark:text-zinc-300">{@meta.warning}</p>

      <ul class="mt-2 divide-y divide-zinc-100 dark:divide-zinc-800/60 border-y border-zinc-100 dark:border-zinc-800/60">
        <li :for={row <- @shown} class="flex items-center gap-3 min-h-11">
          <span class="min-w-0 flex-1 py-1">
            <span class="block truncate font-mono text-meta text-zinc-800 dark:text-zinc-100">
              {row.name}
            </span>
            <span :if={row.note} class="block truncate text-meta text-zinc-500 dark:text-zinc-400">
              {row.note}
            </span>
          </span>
          <span class="flex-none text-meta tabular-nums text-zinc-500 dark:text-zinc-400">
            {Disk.human_bytes(row.size)}
          </span>
          <button
            type="button"
            phx-click="reclaim_one"
            phx-value-group={@key}
            phx-value-name={row.name}
            data-confirm={"Remove #{row.name}? This cannot be undone."}
            disabled={!is_nil(@busy)}
            class="focus-ring flex-none inline-flex items-center justify-center min-h-11 px-3 rounded-sm text-body font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 disabled:opacity-50"
          >
            Remove
          </button>
        </li>
      </ul>
      <p :if={@more > 0} class="mt-1 text-meta text-zinc-500 dark:text-zinc-400">
        and {@more} smaller.
      </p>

      <button
        :if={@meta.bulk}
        type="button"
        phx-click="reclaim_group"
        phx-value-group={@key}
        data-confirm={@meta.confirm}
        disabled={!is_nil(@busy)}
        class={["mt-3", StreamCard.action_class(variant: :primary, tone: :danger)]}
      >
        {@meta.bulk} ({Disk.human_bytes(@total)})
      </button>
    </div>
    """
  end

  defp disk_line(%{free_bytes: free, total_bytes: total}),
    do: "#{Disk.human_bytes(free)} free of #{Disk.human_bytes(total)}."

  defp disk_line(:full), do: "The disk is full."
  defp disk_line(_), do: ""

  defp auto_line(%{last: %{removed: n, freed_bytes: freed, at: at}}, auto) when n > 0 do
    "Last removed #{n} (#{Disk.human_bytes(freed)}) at #{Calendar.strftime(at, "%H:%M")} UTC." <>
      waiting(auto)
  end

  defp auto_line(_status, []), do: "Nothing of its own is waiting to be removed."
  defp auto_line(_status, auto), do: String.trim_leading(waiting(auto))

  defp waiting([]), do: ""

  defp waiting(auto),
    do:
      " #{length(auto)} waiting (#{Disk.human_bytes(GC.total(auto))}); new ones wait 10 minutes."
end
