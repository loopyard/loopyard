defmodule LoopyardWeb.ActivitySound do
  @moduledoc """
  Activity → chime bridge (#61). A pure **subscriber**: it listens to
  `Loopyard.Events.Activity` and fires chimes on `Aural` channels. The core
  never learns it exists — delete this module + `packages/aural` and Loopyard is
  unchanged (enforced by the sound boundary test, #60).

  Lives at the web edge (`lib/loopyard_web/`) precisely because it references
  `Aural`, which the core (`lib/loopyard/`) is forbidden to.

  ## Channels & proximity
  Each activity fires on two channels:
    * a **global** `"activity"` channel — everything, everywhere.
    * a **per-project** `"project-<id>"` channel — just that project.

  Proximity-by-loudness is then a *client* choice: a browser viewing a project
  subscribes to that project's channel (near/loud) plus the global channel
  (far/soft), so distant activity is quieter. The server just fires on both;
  the mixing is per-viewer.

  We chime on **status changes** (the "something happened" moments — a turn
  finishing, a rate-limit, a crash), not on every tool call (far too frequent
  to be anything but noise).
  """
  use GenServer

  @global_channel "activity"

  def start_link(_opts) do
    # Gated by config so tests (and anyone who wants silence) don't spin up
    # ffmpeg/mp3 encoders. Default on for dev/prod; off in test.
    if Application.get_env(:loopyard, :activity_sound, true) do
      GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl true
  def init(:ok) do
    Loopyard.Events.Activity.subscribe_global()
    {:ok, %{}}
  end

  @impl true
  def handle_info(%Loopyard.Events.Activity.Event{kind: :status} = e, state) do
    kind = chime_kind(e.summary)
    Aural.Channel.fire(@global_channel, kind)
    if e.project_id, do: Aural.Channel.fire(project_channel(e.project_id), kind)
    {:noreply, state}
  rescue
    # Sound is decorative — never let a chime failure disturb anything.
    _ -> {:noreply, state}
  catch
    _, _ -> {:noreply, state}
  end

  # Ignore tool-call activity (too frequent to chime) and anything else.
  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Per-project channel id for a project (sanitized to the Aural id charset)."
  def project_channel(project_id), do: "project-#{sanitize(project_id)}"

  defp sanitize(id), do: id |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "")

  # Map status → chime kind (Aural: "done" | "attention" | "alert").
  defp chime_kind(s) when s in ["rate_limited", "auth_expired", "crashed"], do: "alert"
  defp chime_kind("idle"), do: "done"
  defp chime_kind(_), do: "attention"
end
