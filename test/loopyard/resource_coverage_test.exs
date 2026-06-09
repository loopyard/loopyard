defmodule Loopyard.ResourceCoverageTest do
  @moduledoc """
  Static coverage check for Move #7b. Scans `lib/loopyard/` for
  patterns that allocate OS-level or long-lived OTP resources and
  fails the build when a new site appears outside the explicit
  allowlist or the `Resources.track/4` call path.

  ## What it checks

  The janitor releases resources only if the caller tracked them
  via `Resources.track/4`. New code that calls `Port.open/2` or
  hand-manages Mutagen sessions without going through the janitor
  is an invitation to re-introduce the orphan-resource class we
  just killed. The test fails in that case with an explicit
  allowlist entry required — either track the resource or add a
  documented justification.

  ## Allowlist

  Current `Port.open` sites that legitimately don't track via
  `Resources`:

    * `lib/loopyard/docker.ex` — short-lived CLI shell-outs;
      the Port is linked to the calling process (`Docker.docker/2`)
      and dies with it. No lifetime beyond the call.

    * `lib/loopyard/terminal.ex` — GenServer-owned PTY; the
      Port dies with the Terminal GenServer via BEAM Port linking.

    * `lib/loopyard/agent/backend/acp/transport/port.ex` —
      GenServer-owned ACP adapter subprocess; the Port is linked to
      the `Transport.Port` GenServer and dies with it (BEAM Port
      linking), and the adapter exits on stdin EOF. (Future hardening:
      track its OS pid via `Resources` like the claude_cli pid, once
      ACP is wired as the live backend.)

    * `lib/loopyard/volume_cloner.ex` — short-lived git clone
      subprocess, linked to the caller.

    * `lib/loopyard/eval_runner.ex` — short-lived eval
      subprocess, linked to the caller.

    * `lib/loopyard/tools/container/docker_compose.ex` — docker
      compose CLI, short-lived, linked to the caller.

    * `lib/loopyard/tools/container/exec.ex` — docker
      exec CLI with streaming output via Port. Port dies when the
      tool call completes (or times out).

  Mutagen sessions are NOT in scope — the SyncMonitor design
  explicitly preserves them across GenServer restarts (see
  `Loopyard.Resources` @moduledoc).
  """
  use ExUnit.Case, async: true

  # File-system sweeps under full-suite load can exceed the 2s default
  # timeout even though they're <200ms in isolation. 30s gives enough
  # headroom without masking real slowdowns. Applies to every test in
  # this module because they all walk `lib/` the same way.
  @moduletag timeout: 30_000

  @lib_root Path.expand("../../lib/loopyard", __DIR__)

  @port_open_allowlist [
    "lib/loopyard/docker.ex",
    "lib/loopyard/terminal.ex",
    "lib/loopyard/agent/backend/acp/transport/port.ex",
    "lib/loopyard/volume_cloner.ex",
    "lib/loopyard/eval_runner.ex",
    "lib/loopyard/tools/container/docker_compose.ex",
    "lib/loopyard/tools/container/exec.ex"
  ]

  test "every Port.open/2 site is either tracked or in the allowlist" do
    offenders =
      find_pattern_sites("Port.open(")
      |> Enum.reject(fn rel ->
        rel in @port_open_allowlist or String.starts_with?(rel, "lib/loopyard/resources")
      end)

    assert offenders == [], """
    New Port.open/2 site(s) found outside the allowlist:

    #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

    If this Port's lifetime is bounded by the calling process (linked
    to a GenServer or short-lived Task), add it to @port_open_allowlist
    in #{__MODULE__} with a one-line justification. Otherwise, track it
    via Loopyard.Resources.track/4 so the janitor can release it
    when the owner dies.
    """
  end

  test "no module outside Resources.* calls :telemetry.execute for the :resources namespace" do
    # Guard against accidental re-emission of resource telemetry from
    # unexpected sites — the single emitter is Resources.Janitor so
    # /system/orphans and downstream dashboards stay consistent.
    offenders =
      find_pattern_sites(":loopyard, :resources")
      |> Enum.reject(fn rel ->
        String.starts_with?(rel, "lib/loopyard/resources") or
          String.starts_with?(rel, "lib/loopyard/events_tap") or
          rel == "lib/loopyard/resources.ex"
      end)

    assert offenders == [], """
    Unexpected :resources telemetry emission from:

    #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

    Resource telemetry should only fire from Loopyard.Resources.Janitor.
    """
  end

  # --- Helpers ---

  defp find_pattern_sites(pattern) do
    Path.wildcard(Path.join(@lib_root, "**/*.ex"))
    |> Enum.filter(fn file ->
      case File.read(file) do
        {:ok, content} -> String.contains?(content, pattern)
        _ -> false
      end
    end)
    |> Enum.map(&Path.relative_to(&1, Path.expand("../..", __DIR__)))
    |> Enum.sort()
  end
end
