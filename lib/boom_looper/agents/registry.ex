defmodule BoomLooper.Agents.Registry do
  @moduledoc """
  Discovery and lookup of agent definitions.

  Agents live in folders on disk. The registry resolves an agent name
  to its folder using this order (first match wins):

    1. Per-project: `.boomlooper/repo/agents/<name>/` (not implemented in phase 1)
    2. User-global: `~/.boomlooper/agents/<name>/`
    3. Built-in:    `priv/agents/<name>/` (shipped with BoomLooper)

  Phase 1 ships the built-in tier plus the user-global tier. The
  per-project tier will arrive once we have a workspace-aware lookup.
  """

  alias BoomLooper.Agents.{Agent, Loader}

  @default_agent "coding"

  @doc "The fallback agent type when none is specified on spawn."
  def default_agent_name, do: @default_agent

  @doc """
  List all available agents, merging across resolution tiers. When
  two tiers define the same name, the higher-precedence tier wins.
  Results are sorted by name.
  """
  def list do
    user_tier = list_in(user_root())
    builtin_tier = list_in(builtin_root())

    (user_tier ++ builtin_tier)
    |> Enum.reduce(%{}, fn {name, folder}, acc ->
      Map.put_new(acc, name, folder)
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map(fn {_name, folder} ->
      case Loader.load(folder) do
        {:ok, agent} -> agent
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Look up an agent by name. Returns `{:ok, %Agent{}}` or `{:error, reason}`.
  """
  def get(name) when is_binary(name) do
    case folder_for(name) do
      {:ok, folder} -> Loader.load(folder)
      :error -> {:error, "agent not found: #{name}"}
    end
  end

  @doc """
  Return the on-disk folder for an agent name, searching the resolution
  order. Returns `{:ok, path}` or `:error`.
  """
  def folder_for(name) when is_binary(name) do
    if safe_name?(name) do
      [user_root(), builtin_root()]
      |> Enum.map(&Path.join(&1, name))
      |> Enum.find(fn path -> File.dir?(path) and File.regular?(Path.join(path, "agent.md")) end)
      |> case do
        nil -> :error
        path -> {:ok, path}
      end
    else
      :error
    end
  end

  @doc """
  List the files available inside an agent's folder (recursively).
  Returns paths relative to the folder, sorted. Used to generate the
  catalog injected into the system prompt.

  `agent.md` and `Dockerfile` are excluded — they're BoomLooper's own
  metadata, not content for the agent to read.
  """
  def catalog(%Agent{folder: folder}), do: catalog(folder)

  def catalog(folder) when is_binary(folder) do
    folder
    |> list_files_recursive()
    |> Enum.reject(fn rel -> rel in ["agent.md", "Dockerfile"] end)
    |> Enum.sort()
  end

  # --- Resolution roots ---

  defp builtin_root do
    Application.app_dir(:boom_looper, "priv/agents")
  end

  defp user_root do
    Path.join(user_home(), ".boomlooper/agents")
  end

  defp user_home do
    System.get_env("BOOMLOOPER_HOME") || System.user_home() || ""
  end

  defp list_in(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn name -> {name, Path.join(root, name)} end)
        |> Enum.filter(fn {_name, path} ->
          File.dir?(path) and File.regular?(Path.join(path, "agent.md"))
        end)

      _ ->
        []
    end
  end

  # Reject anything that could escape the resolution root. Agent names
  # come from the frontmatter on spawn; the registry validates them
  # before joining to a path.
  defp safe_name?(name) do
    name != "" and
      not String.contains?(name, "/") and
      not String.contains?(name, "\\") and
      not String.contains?(name, "..") and
      not String.starts_with?(name, ".")
  end

  defp list_files_recursive(folder) do
    Path.wildcard(Path.join([folder, "**", "*"]))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn path ->
      Path.relative_to(path, folder) |> to_string()
    end)
  end
end
