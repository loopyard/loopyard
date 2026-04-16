defmodule BoomLooper.ChatAgent.ClaudeContext do
  @moduledoc """
  Makes the project's `CLAUDE.md` and `.claude/` config visible to the
  Claude Code CLI that BoomLooper spawns on the host.

  The CLI walks from `cwd` looking for:

    * `CLAUDE.md` (project memory)
    * `CLAUDE.local.md` (personal overrides)
    * `.claude/CLAUDE.md`
    * `.claude/settings.json`
    * `.claude/settings.local.json`

  and resolves `@path/to/file.md` imports (max 5 hops) relative to the
  importing file.

  ## Why we have to do anything at all

  Local workspaces: `working_dir` is the host project dir. Mutagen keeps
  it in sync with the volume. The CLI reads everything natively — we
  have nothing to do.

  GitHub workspaces: `working_dir` is a virtual bookkeeping dir
  (`~/.boomlooper/workspaces/<id>`); the code lives only in the code
  volume. Without help, the CLI sees nothing. We read the expected
  files out of the volume and write them into `working_dir` before the
  session starts so the CLI's normal discovery finds them.

  The mirror is best-effort — missing files, no volume, or read errors
  are not fatal. The agent just doesn't get that context.
  """

  require Logger

  @max_import_hops 5

  # Runtime-swappable so tests can inject a fake (see claude_context_test.exs).
  # Production always uses BoomLooper.VolumeIO.
  defp volume_reader, do: Application.get_env(:boom_looper, :volume_reader, BoomLooper.VolumeIO)

  @well_known_files [
    "CLAUDE.md",
    "CLAUDE.local.md",
    ".claude/CLAUDE.md",
    ".claude/settings.json",
    ".claude/settings.local.json"
  ]

  @import_regex ~r/@([\w\-\.\/]+\.md)/

  @doc """
  Mirror CLAUDE.md + `.claude/` from the workspace volume into
  `working_dir`. Returns `{:ok, paths_written}` with the relative paths
  we wrote, or `:skip` / `{:error, reason}`.

  Skips entirely when `working_dir` already contains a `CLAUDE.md` —
  that's a Local workspace where the host is already the source of
  truth, and overwriting would clobber the user's work.
  """
  def mirror(workspace_id, working_dir) when is_binary(workspace_id) and is_binary(working_dir) do
    cond do
      not File.dir?(working_dir) ->
        :skip

      has_host_claude?(working_dir) ->
        :skip

      true ->
        mirror_from_volume(workspace_id, working_dir)
    end
  end

  def mirror(_, _), do: :skip

  # --- Internals ---

  defp has_host_claude?(working_dir) do
    File.exists?(Path.join(working_dir, "CLAUDE.md"))
  end

  defp mirror_from_volume(workspace_id, working_dir) do
    volume = BoomLooper.VolumeManager.code_volume_name(workspace_id)

    # Pull the entire .claude/ tree in one docker round-trip so skills,
    # commands, agents, and hooks tag along without per-file reads.
    mirror_claude_dir(volume, working_dir)

    written = mirror_well_known(volume, working_dir, []) ++ mirror_imports(volume, working_dir)

    # Count .claude/ files that the directory mirror wrote so the log
    # accurately reflects what the agent will see.
    claude_tree = list_mirrored_claude_files(working_dir)
    total = Enum.uniq(written ++ claude_tree)

    if total == [] do
      :skip
    else
      Logger.info(
        "[ClaudeContext] mirrored #{length(total)} file(s) from " <>
          "#{volume} → #{working_dir}"
      )

      # Surface to EventLog so users can see CLAUDE.md was picked up.
      # The agent won't say "I read CLAUDE.md" — this is the only signal.
      has_claude_md? = Enum.any?(total, &String.ends_with?(&1, "CLAUDE.md"))
      claude_dir_count = Enum.count(total, &String.starts_with?(&1, ".claude/"))
      note = if has_claude_md?, do: "CLAUDE.md + ", else: ""

      BoomLooper.EventLog.info(
        "agent:context",
        "Loaded #{length(total)} Claude Code file(s) (#{note}#{claude_dir_count} .claude/ entries)"
      )

      {:ok, total}
    end
  rescue
    e ->
      Logger.warning("[ClaudeContext] mirror failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp mirror_claude_dir(volume, working_dir) do
    case volume_reader() do
      mod when is_atom(mod) ->
        if function_exported?(mod, :mirror_dir, 3) do
          mod.mirror_dir(volume, ".claude", working_dir)
        else
          :ok
        end
    end
  end

  defp list_mirrored_claude_files(working_dir) do
    claude_dir = Path.join(working_dir, ".claude")

    if File.dir?(claude_dir) do
      claude_dir
      |> Path.join("**")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, working_dir))
    else
      []
    end
  end

  defp mirror_well_known(volume, working_dir, acc) do
    Enum.reduce(@well_known_files, acc, fn rel_path, acc ->
      case volume_reader().read_file(volume, rel_path) do
        {:ok, content} when is_binary(content) and content != "" ->
          write_to_host(working_dir, rel_path, content)
          [rel_path | acc]

        _ ->
          acc
      end
    end)
  end

  # Walk @imports starting from any CLAUDE*.md we mirrored. For every
  # referenced file, read from volume, write to host, and recurse on its
  # own @imports. We cap at @max_import_hops levels.
  defp mirror_imports(volume, working_dir) do
    seeds =
      @well_known_files
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.filter(&File.exists?(Path.join(working_dir, &1)))

    {_seen, written} =
      Enum.reduce(seeds, {MapSet.new(), []}, fn seed, {seen, written} ->
        crawl_imports(volume, working_dir, seed, seen, written, 0)
      end)

    written
  end

  defp crawl_imports(_volume, _working_dir, _parent_rel, seen, written, hop)
       when hop >= @max_import_hops,
       do: {seen, written}

  defp crawl_imports(volume, working_dir, parent_rel, seen, written, hop) do
    parent_path = Path.join(working_dir, parent_rel)

    case File.read(parent_path) do
      {:ok, content} ->
        content
        |> extract_imports(parent_rel)
        |> Enum.reduce({seen, written}, fn import_rel, {seen, written} ->
          cond do
            MapSet.member?(seen, import_rel) ->
              {seen, written}

            true ->
              seen = MapSet.put(seen, import_rel)

              case volume_reader().read_file(volume, import_rel) do
                {:ok, imported} when is_binary(imported) and imported != "" ->
                  write_to_host(working_dir, import_rel, imported)
                  crawl_imports(volume, working_dir, import_rel, seen, [import_rel | written], hop + 1)

                _ ->
                  {seen, written}
              end
          end
        end)

      _ ->
        {seen, written}
    end
  end

  defp extract_imports(content, parent_rel) do
    parent_dir = Path.dirname(parent_rel)

    Regex.scan(@import_regex, content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(fn ref ->
      if String.starts_with?(ref, "/") do
        String.trim_leading(ref, "/")
      else
        parent_dir
        |> Path.join(ref)
        |> Path.expand("/")
        |> String.trim_leading("/")
      end
    end)
    |> Enum.reject(&path_escapes?/1)
    |> Enum.uniq()
  end

  defp path_escapes?(rel) do
    # Defense: never let a resolved import path climb above the
    # workspace root. `Path.expand` with absolute "/" anchor should
    # prevent `..` from escaping, but belt-and-suspenders.
    String.contains?(rel, "..")
  end

  defp write_to_host(working_dir, rel_path, content) do
    target = Path.join(working_dir, rel_path)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, content)
  end
end
