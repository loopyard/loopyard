defmodule Loopyard.Agents.Coding do
  @moduledoc """
  THE agent. One self-determining coding agent — it reads the situation
  (`service_containers`, the workspace) and acts: bootstraps the dev environment
  only if missing, otherwise just codes. Its definition (`agent.md`) and the
  support files it reads on demand (setup guide, per-stack templates) live in
  `priv/agents/coding/`.

  There used to be multiple "agent types" behind a registry with user/builtin
  resolution tiers + an `agent_type` parameter threaded through every spawn
  path. That concept was removed — a registry of one is pure overhead — so this
  is a thin accessor to the single agent's folder.
  """

  alias Loopyard.Agents.Loader

  @doc "On-disk folder holding the agent definition + its support files."
  def folder, do: Application.app_dir(:loopyard, "priv/agents/coding")

  @doc "Load the agent definition (`agent.md` body + frontmatter) as `%Agent{}`."
  def definition, do: Loader.load(folder())

  @doc """
  Support files the agent can `read_agent_file` on demand — relative paths,
  sorted. Excludes `agent.md`/`Dockerfile` (Loopyard's own metadata, not
  content for the agent to read).
  """
  def catalog do
    folder = folder()

    Path.wildcard(Path.join([folder, "**", "*"]))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&(Path.relative_to(&1, folder) |> to_string()))
    |> Enum.reject(&(&1 in ["agent.md", "Dockerfile"]))
    |> Enum.sort()
  end
end
