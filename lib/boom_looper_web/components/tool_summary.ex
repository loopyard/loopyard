defmodule BoomLooperWeb.Components.ToolSummary do
  @moduledoc """
  Generates human-readable one-line summaries of tool calls.
  Used in the chat UI to show what the agent is doing.
  """

  import BoomLooperWeb.Format, only: [shorten_path: 1]

  @doc "Summarize a tool call into a short human-readable string."
  def summarize(tool_name, input) when is_map(input) do
    clean_name = tool_name |> String.replace(~r/^mcp__[\w-]+__/, "")

    case {clean_name, input} do
      {"Read", %{"file_path" => path}} -> "Read #{shorten_path(path)}"
      {"Write", %{"file_path" => path}} -> "Wrote #{shorten_path(path)}"
      {"Edit", %{"file_path" => path}} -> "Edited #{shorten_path(path)}"
      {"Bash", %{"command" => cmd}} -> "$ #{String.slice(cmd, 0..80)}"
      {"Grep", %{"pattern" => pat}} -> "Searched for \"#{pat}\""
      {"Glob", %{"pattern" => pat}} -> "Found files matching #{pat}"
      {"Agent", %{"prompt" => p}} -> "Spawned agent: #{String.slice(p, 0..60)}"
      {"list_agents", _} -> "Listed all agents"
      {"spawn_agent", %{"name" => n}} -> "Spawned agent #{n}"
      {"send_message_to_agent", %{"agent_id" => id}} -> "Sent message to agent #{String.slice(id, 0..8)}"
      {"stop_agent", %{"agent_id" => id}} -> "Stopped agent #{String.slice(id, 0..8)}"
      {"exec", %{"command" => cmd}} -> "container $ #{String.slice(cmd, 0..80)}"
      {"exec_stream", %{"command" => cmd}} -> "container $ #{String.slice(cmd, 0..80)}"
      {"logs", _} -> "Checked container logs"
      {"inspect_env", _} -> "Inspected container environment"
      {"start_service", %{"name" => n, "command" => cmd}} -> "Started service #{n}: #{String.slice(cmd, 0..60)}"
      {"start_service", %{"name" => n}} -> "Started service #{n}"
      {"ports", _} -> "Listed container ports"
      {"set_dockerfile", _} -> "Updated Dockerfile"
      {"set_dev_command", %{"command" => cmd}} -> "Dev command: #{String.slice(cmd, 0..60)}"
      {"set_dev_command", _} -> "Set dev command"
      {"add_service", %{"name" => n}} -> "Added service: #{n}"
      {"remove_service", %{"name" => n}} -> "Removed service: #{n}"
      {"set_env_vars", _} -> "Updated environment variables"
      {"set_workspace_name", %{"name" => n}} -> "Named project: #{n}"
      {"set_system_prompt", _} -> "Updated system prompt"
      {"start_services", _} -> "Started services"
      {"stop_services", _} -> "Stopped services"
      {"rebuild", _} -> "Rebuilding..."
      {"service_status", _} -> "Checked service status"
      {"service_containers", _} -> "Service containers"
      {"list_secrets", _} -> "Listed available secrets"
      {"get_secret", %{"key" => k}} -> "Retrieved secret: #{k}"
      {"ToolSearch", _} -> "Claude is loading tools..."
      {"WebSearch", %{"query" => q}} -> "Web search: #{String.slice(q, 0..60)}"
      {"WebFetch", %{"url" => url}} -> "Fetching #{String.slice(url, 0..80)}"
      {name, _} -> name |> String.replace("_", " ") |> String.capitalize()
    end
  end

  def summarize(tool_name, _input), do: tool_name
end
