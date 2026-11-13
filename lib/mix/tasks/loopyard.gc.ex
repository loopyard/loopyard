defmodule Mix.Tasks.Loopyard.Gc do
  @moduledoc """
  Reclaim Docker space that is provably Loopyard's own AND provably unused
  (issue #117) — dangling test-suite volumes, stopped sign-in / copy
  throwaway containers, superseded base-image tags. The selection rules are
  in `Loopyard.GC`; this task only lists, prints and (on `--apply`) removes.

  ## Usage

      mix loopyard.gc            # DRY RUN: every candidate with its size, and a total
      mix loopyard.gc --apply    # remove them (never forced — Docker refuses in-use ones)

  It never touches a workspace's code volume, a workstation home volume, a
  compose project's volumes, or anything without a Loopyard-owned name. After
  the candidates it lists the largest OTHER volumes and images — what else is
  filling the disk, for you to decide about (`docker system df -v`).

  Talks to the Docker daemon directly; it does NOT boot Loopyard (a second
  instance would reap the running server's harnesses).
  """

  use Mix.Task

  alias Loopyard.Docker.Disk
  alias Loopyard.GC
  alias Loopyard.GC.Runner

  @shortdoc "Reclaim Loopyard's own unused Docker volumes, containers and images"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: [apply: :boolean])
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:telemetry)

    with {:ok, listings} <- Runner.listings(),
         {:ok, candidates} <- GC.select(listings, Runner.opts()) do
      print_candidates(candidates)
      print_others(GC.largest_other(listings, candidates))

      if opts[:apply], do: apply!(candidates), else: hint(candidates)
    else
      {:error, reason} -> Mix.raise("loopyard.gc: #{reason}")
    end
  end

  defp print_candidates([]), do: Mix.shell().info("Nothing of Loopyard's own to reclaim.")

  defp print_candidates(candidates) do
    Mix.shell().info("Reclaimable (Loopyard's own, unused):")

    candidates
    |> Enum.group_by(& &1.kind)
    |> Enum.each(fn {kind, list} ->
      Mix.shell().info("\n  #{kind}s (#{length(list)}, #{Disk.human_bytes(GC.total(list))})")
      Enum.each(list, &Mix.shell().info("    #{pad(Disk.human_bytes(&1.size))}  #{&1.name}"))
    end)

    Mix.shell().info(
      "\nTotal: #{length(candidates)} item(s), #{Disk.human_bytes(GC.total(candidates))}"
    )
  end

  defp print_others([]), do: :ok

  defp print_others(others) do
    Mix.shell().info("\nNot touched - the largest other things on the disk (your call):")

    Enum.each(
      others,
      &Mix.shell().info("    #{pad(Disk.human_bytes(&1.size))}  #{&1.kind}  #{&1.name}")
    )
  end

  defp hint([]), do: :ok
  defp hint(_), do: Mix.shell().info("\nDry run. Re-run with --apply to remove the above.")

  defp apply!(candidates) do
    %{removed: removed, failed: failed} = Runner.remove(candidates)

    Mix.shell().info(
      "\nRemoved #{length(removed)} item(s), #{Disk.human_bytes(GC.total(removed))}."
    )

    Enum.each(failed, fn {c, why} -> Mix.shell().error("  kept #{c.name}: #{why}") end)
  end

  defp pad(s), do: String.pad_leading(s, 8)
end
