defmodule Loopyard.PubSubBoundaryTest do
  @moduledoc """
  Move #2 of plans/archive/coordination-hardening.md — CI boundary enforcement.

  Every PubSub broadcast in `lib/` MUST go through a publisher module
  under `lib/loopyard/events/`. Raw `Phoenix.PubSub.broadcast` calls
  anywhere else are forbidden — they were the source of the
  broadcast-slop bug class (typo'd topics, drifted payload shapes,
  subscribers silently missing events).

  This test greps `lib/` for the forbidden pattern and fails with the
  offending file:line pairs. Moving a broadcast back outside the
  publisher module trips CI, so the constraint survives contributor
  turnover without requiring anyone to remember the rule.

  Comments and strings containing "Phoenix.PubSub.broadcast" are
  allowed — only actual function calls count as violations.
  """

  use ExUnit.Case, async: true

  @allowed_prefix "lib/loopyard/events/"

  # File-system sweep under full-suite load can exceed the 2s default
  # timeout even though it's <200ms in isolation. 30s gives enough
  # headroom without masking real slowdowns.
  @tag timeout: 30_000
  test "no raw Phoenix.PubSub.broadcast calls outside publisher modules" do
    violations =
      lib_files()
      |> Enum.flat_map(&find_violations/1)
      |> Enum.reject(fn {path, _, _} -> String.starts_with?(path, @allowed_prefix) end)

    assert violations == [],
           "Raw Phoenix.PubSub.broadcast calls are forbidden outside #{@allowed_prefix}. " <>
             "Route these through a Loopyard.Events.* publisher module. " <>
             "Offenders:\n" <>
             Enum.map_join(violations, "\n", fn {path, line, text} ->
               "  #{path}:#{line}: #{text}"
             end)
  end

  # ── Helpers ──

  defp lib_files do
    Path.wildcard("lib/**/*.ex")
  end

  defp find_violations(path) do
    content = File.read!(path)

    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, idx} ->
      trimmed = String.trim_leading(line)

      cond do
        # Skip comments — the word can appear in docstrings / inline comments
        String.starts_with?(trimmed, "#") ->
          []

        # Only care about actual call sites. `Phoenix.PubSub.broadcast(` /
        # `Phoenix.PubSub.broadcast!(` / `Phoenix.PubSub.broadcast_from(`.
        Regex.match?(~r/Phoenix\.PubSub\.broadcast[!_]?[(_]/, line) ->
          [{relative(path), idx, String.trim(line)}]

        true ->
          []
      end
    end)
  end

  defp relative(path) do
    cwd = File.cwd!()

    if String.starts_with?(path, cwd) do
      path
      |> String.replace_prefix(cwd <> "/", "")
    else
      path
    end
  end
end
