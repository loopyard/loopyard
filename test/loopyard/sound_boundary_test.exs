defmodule Loopyard.SoundBoundaryTest do
  @moduledoc """
  Sound decoupling enforcement (#60) — the escape hatch for #61's activity sound.

  Sound is a **subscriber, never a dependency**: the core broadcasts activity
  over PubSub, and the sound layer (the `:aural` package + a bridge at the web
  edge) *listens* and turns events into chimes. The core must never learn sound
  exists — so no module under `lib/loopyard/` (the core, excluding
  `lib/loopyard_web/`) may reference `Aural` or the sound bridge.

  This is what makes the whole thing rip-out-able: delete `packages/aural` and
  the bridge and the core is byte-for-byte unchanged. This test greps the core
  and fails with the offending file:line, so the decoupling survives contributor
  turnover without anyone having to remember the rule. Comments are allowed (the
  word can appear in a docstring); only real code references count.
  """
  use ExUnit.Case, async: true

  # The sound feature's OWN surface — files that ARE the sound layer, not core
  # depending on it. Ripping out sound means deleting these too, so the
  # rip-out-ability guarantee holds:
  #   * events/aural.ex — the sound-bridge publisher (broadcasts must live in
  #     lib/loopyard/events/ per the PubSub boundary rule, so it can't move to
  #     the web edge).
  #   * tools/control_plane/music.ex — the operator's music tool; its whole job
  #     is driving Aural.Channel.
  # Anything else referencing Aural is still a violation.
  @sound_surface [
    "lib/loopyard/events/aural.ex",
    "lib/loopyard/tools/control_plane/music.ex"
  ]

  @tag timeout: 30_000
  test "core (lib/loopyard/**) contains no references to the sound layer" do
    violations =
      "lib/loopyard/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&(relative(&1) in @sound_surface))
      |> Enum.flat_map(&find_violations/1)

    assert violations == [],
           "The core must not reference the sound layer (Aural / the sound bridge) — " <>
             "sound is a subscriber, not a dependency (see #60). Move the reference to " <>
             "the web edge (lib/loopyard_web/). Offenders:\n" <>
             Enum.map_join(violations, "\n", fn {path, line, text} ->
               "  #{path}:#{line}: #{text}"
             end)
  end

  defp find_violations(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, idx} ->
      trimmed = String.trim_leading(line)

      cond do
        String.starts_with?(trimmed, "#") -> []
        Regex.match?(~r/\bAural\b|:aural\b/, line) -> [{relative(path), idx, String.trim(line)}]
        true -> []
      end
    end)
  end

  defp relative(path) do
    cwd = File.cwd!()
    if String.starts_with?(path, cwd), do: String.replace_prefix(path, cwd <> "/", ""), else: path
  end
end
