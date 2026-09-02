defmodule Loopyard.ChatAgent.Prompt do
  @moduledoc """
  System prompt construction for ChatAgent sessions — the CONTEXT of an
  agent, composed from its template (`Loopyard.Agents.Template`):

      facts (agent id, where it runs)
      + the template's shared doctrine blocks (priv/agents/_shared/*.md)
      + the template's own body (priv/agents/<id>/agent.md)
      + the catalog of files it can read on demand
      + workspace context (name + the workspace's own system prompt)
      + service context

  Pure functions. There is no override path: every agent, the system agent
  included, is composed the same way — that is what lets the shared doctrine
  live in ONE file instead of being duplicated per agent.
  """
  require Logger

  alias Loopyard.Agents.Template

  # A *runaway guardrail*, NOT a hard boundary (the brief travels as a file in
  # the volume or as a config env, never as one CLI argument any more): if a
  # prompt blows past it, something (a whole file, a giant definition) leaked
  # in and should move into an on-demand agent file.
  @max_system_prompt_chars 16_000

  @doc """
  Build the system prompt for an agent session.

  Options: `:template` (a `%Template{}`) or `:template_id` (default
  `"coding"`), `:workspace_id`, `:workspace` (the `%Loopyard.Workspace{}`
  config), `:service_name`, `:name`, `:workstation_identity`.
  """
  def build_system_prompt(agent_id, opts) when is_list(opts) do
    template =
      Keyword.get(opts, :template) || Template.fetch!(Keyword.get(opts, :template_id, "coding"))

    prompt =
      [
        facts(agent_id, template, opts),
        Template.blocks(template),
        template.body,
        catalog_section(template),
        workspace_prompt(Keyword.get(opts, :workspace)),
        service_prompt(Keyword.get(opts, :service_name), Keyword.get(opts, :workspace_id))
      ]
      |> List.flatten()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    warn_if_too_long(prompt)
    prompt
  end

  @doc false
  def facts(agent_id, %Template{compute: :workspace}, opts) do
    "YOUR AGENT ID: #{agent_id} — pass agent_id to every tool call. " <>
      "Workspace: #{Keyword.get(opts, :workspace_id)}."
  end

  def facts(agent_id, %Template{compute: :workstation} = t, opts) do
    name = Keyword.get(opts, :name) || t.name
    identity = Keyword.get(opts, :workstation_identity)

    "YOUR AGENT ID: #{agent_id} — pass this EXACT string as the `agent_id` argument " <>
      "to every tool call. Do not use any other value.\n\n" <>
      "You are #{name}, a system agent" <>
      if(identity, do: " (workstation #{identity}).", else: ".")
  end

  defp catalog_section(template) do
    case Template.catalog(template) do
      [] -> ""
      files -> "Agent files (use `read_agent_file`): " <> Enum.join(files, ", ")
    end
  end

  defp warn_if_too_long(prompt) do
    if String.length(prompt) > @max_system_prompt_chars do
      Logger.warning(
        "[ChatAgent] System prompt is #{String.length(prompt)} chars " <>
          "(limit #{@max_system_prompt_chars}). Move content into agent files."
      )
    end
  end

  @doc false
  def workspace_prompt(nil), do: ""

  def workspace_prompt(workspace) do
    name = Map.get(workspace, :name) || "Unnamed"
    custom = Map.get(workspace, :system_prompt)

    custom_block = if custom, do: "\n#{custom}", else: ""
    "## Workspace: #{name}#{custom_block}"
  end

  @doc false
  def service_prompt(nil, _), do: ""
  def service_prompt(_, nil), do: ""

  def service_prompt(service_name, workspace_id) do
    container =
      Loopyard.Workspace.ServiceManager.service_container_name(workspace_id, service_name)

    "Service agent for #{service_name} (container: #{container}). Use `logs` to check output."
  end
end
