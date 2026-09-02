defmodule Loopyard.Tools.ControlPlane.Music do
  @moduledoc """
  The operator controls the ambient sound. Track + status are server-side
  (`Aural.Channel`, crossfades for every listener); play/pause/volume are the
  browser's playback, bridged to the client via `Loopyard.Events.Aural` (the sound
  pill reflects the result). One verb + an action, so the tool count stays lean.
  """
  use Loopyard.Tool,
    name: "music",
    description:
      "Control the ambient sound. action=status shows the current track + level; " <>
        "action=list shows the available tracks; action=track (with `track`) " <>
        "switches the bed (crossfades for everyone); action=play/pause toggles " <>
        "playback; action=volume (with `level` 0.0–1.0) sets loudness; " <>
        "action=chime (with `chime` done|attention|alert) rings a bell for everyone " <>
        "listening. The sound pill reflects these.",
    busy_words: ["working the music"],
    params: [
      agent_id: {:string, required: true},
      action:
        {:string,
         required: true, description: "status | list | track | play | pause | volume | chime"},
      track: {:string, description: "For action=track: the track name (see action=list)."},
      chime: {:string, description: "For action=chime: done | attention | alert."},
      level: {:number, description: "For action=volume: 0.0–1.0."}
    ]

  @channel "activity"

  def execute(params, _assigns) do
    case (params[:action] || "") |> to_string() |> String.downcase() do
      "status" ->
        status()

      "list" ->
        {:ok, "Available tracks: #{Enum.join(tracks(), ", ")}. Switch with action=track."}

      "track" ->
        track(params[:track])

      "play" ->
        command(:play, nil, "Playing the ambient bed.")

      "pause" ->
        command(:pause, nil, "Paused the ambient bed.")

      "volume" ->
        volume(params[:level])

      "chime" ->
        chime(params[:chime])

      other ->
        {:error,
         "Unknown action '#{other}'. Use status, list, track, play, pause, volume, or chime."}
    end
  rescue
    e -> {:error, "music failed: #{inspect(e)}"}
  end

  defp status do
    st = Aural.Channel.state(@channel) || %{}
    level = Float.round((st[:activity] || 0.0) * 1.0, 2)

    {:ok,
     "Track: #{st[:track] || "?"} · activity level #{level}. (Play/pause + volume " <>
       "are per-listener; the sound pill shows the current state.)"}
  end

  defp track(name) when is_binary(name) and name != "" do
    if name in tracks() do
      Aural.Channel.pick_track(@channel, name)
      {:ok, "Switched the ambient bed to '#{name}' (crossfading)."}
    else
      {:error, "Unknown track '#{name}'. Available: #{Enum.join(tracks(), ", ")}."}
    end
  end

  defp track(_), do: {:error, "action=track needs a `track` name (see action=list)."}

  defp volume(level) when is_number(level) do
    command(:volume, level * 1.0, "Set volume to #{Float.round(level * 1.0, 2)}.")
  end

  defp volume(_), do: {:error, "action=volume needs a `level` between 0.0 and 1.0."}

  defp chime(kind) when kind in ["done", "attention", "alert"] do
    Aural.Channel.fire(@channel, kind)
    {:ok, "Rang the '#{kind}' chime for everyone listening."}
  end

  defp chime(_), do: {:error, "action=chime needs `chime`: done, attention, or alert."}

  defp command(action, value, msg) do
    Loopyard.Events.Aural.command(action, value)
    {:ok, msg <> " (applied to your open session; the sound pill reflects it.)"}
  end

  defp tracks, do: Aural.Synth.track_names()
end
