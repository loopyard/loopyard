defmodule Loopyard.HotReload do
  @moduledoc """
  Hot-reload helpers for the running Loopyard node.

  `IEx.Helpers.recompile/0` alone is not sufficient when `mix compile`
  has already been run in a separate shell: it compares source
  timestamps against its in-memory compile log, sees they agree, and
  returns `:noop` — leaving the BEAM with the OLD module bytecode.

  This helper covers both paths. Call from `mix loopyard.rpc`:

      mix loopyard.rpc 'Loopyard.HotReload.reload()'
      mix loopyard.rpc 'Loopyard.HotReload.reload(Loopyard.ChatAgent)'

  Symptom that tells you the fix you hot-reloaded didn't take effect:
  a tool output or log line still matches the pre-fix text even after
  `IEx.Helpers.recompile()` returned `:noop`. That's the trap this
  module exists to avoid.
  """

  @doc """
  Recompile the project AND force-reload every module under the
  `Loopyard` and `LoopyardWeb` namespaces whose .beam file on
  disk is newer than what the BEAM has loaded. Returns the list of
  reloaded module names.

  Safe to call repeatedly — a module that's already up-to-date is
  skipped.
  """
  def reload do
    IEx.Helpers.recompile()
    force_reload_stale()
  end

  @doc """
  Force-reload a specific module or list of modules regardless of
  staleness. Useful when you know you changed source files that the
  mix-level compile heuristic missed.
  """
  def reload(modules) when is_list(modules) do
    Enum.map(modules, &force_reload/1)
  end

  def reload(module) when is_atom(module), do: reload([module]) |> List.first()

  # --- Private ---

  defp force_reload_stale do
    # "Stale" here means: the on-disk .beam file's mtime is newer
    # than when the BEAM loaded this module. That's conservative —
    # we only reload what's actually been recompiled since the last
    # load. Modules we can't stat fall through and are skipped.
    start = System.monotonic_time(:second) - 60

    for {module, path} <- :code.all_loaded(),
        is_list(path),
        boom_module?(module),
        newer_than?(path, start) do
      force_reload(module)
      module
    end
  end

  defp boom_module?(module) do
    name = Atom.to_string(module)

    String.starts_with?(name, "Elixir.Loopyard.") or
      String.starts_with?(name, "Elixir.LoopyardWeb.")
  end

  # True if the .beam file was written in the last ~60 seconds. Cheap
  # heuristic for "mix compile just updated this file, BEAM still has
  # the old copy." Safer than loading every module blindly.
  defp newer_than?(path, threshold_epoch_seconds) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime >= threshold_epoch_seconds
      _ -> false
    end
  end

  defp force_reload(module) do
    :code.purge(module)
    :code.load_file(module)
  end
end
