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
      {"Read", %{"file_path" => path}} ->
        "Read #{shorten_path(path)}"

      {"Write", %{"file_path" => path}} ->
        "Wrote #{shorten_path(path)}"

      {"Edit", %{"file_path" => path}} ->
        "Edited #{shorten_path(path)}"

      {"Bash", %{"command" => cmd}} ->
        "$ #{String.slice(cmd, 0..80)}"

      {"Grep", %{"pattern" => pat}} ->
        "Searched for \"#{pat}\""

      {"Glob", %{"pattern" => pat}} ->
        "Found files matching #{pat}"

      {"Agent", %{"prompt" => p}} ->
        "Spawned agent: #{String.slice(p, 0..60)}"

      {"list_agents", _} ->
        "Listed all agents"

      {"spawn_agent", %{"name" => n}} ->
        "Spawned agent #{n}"

      {"send_message_to_agent", %{"agent_id" => id}} ->
        "Sent message to agent #{String.slice(id, 0..8)}"

      {"stop_agent", %{"agent_id" => id}} ->
        "Stopped agent #{String.slice(id, 0..8)}"

      {"exec", _} ->
        "Execute"

      {"read_files", %{"paths" => paths}} when is_list(paths) ->
        "Read #{length(paths)} files"

      {"read_files", _} ->
        "Read files"

      {"multi_edit", %{"file_path" => path}} ->
        "Multi-edit #{shorten_path(path)}"

      {"multi_edit", _} ->
        "Multi-edit"

      {"file_info", %{"path" => path}} ->
        "File info #{shorten_path(path)}"

      {"file_info", _} ->
        "File info"

      {"tree", _} ->
        "Tree"

      {"docker_compose", %{"action" => action}} ->
        "Docker compose #{action}"

      {"docker_compose", _} ->
        "Docker compose"

      {"probe_http", %{"url" => url}} ->
        "Probe #{String.slice(url, 0..40)}"

      {"probe_http", _} ->
        "Probe HTTP"

      {"git", %{"command" => cmd}} ->
        "Git #{String.slice(cmd, 0..40)}"

      {"git", _} ->
        "Git"

      {"inspect_service", %{"name" => n}} ->
        "Inspect #{n}"

      {"inspect_service", _} ->
        "Inspect service"

      {"app_url", _} ->
        "App URL"

      {"file_url", _} ->
        "File URL"

      {"workspace_info", _} ->
        "Workspace info"

      {"logs", _} ->
        "Logs"

      {"inspect_env", _} ->
        "Inspect environment"

      {"start_service", %{"name" => n}} ->
        "Start service #{n}"

      {"start_service", _} ->
        "Start service"

      {"ports", _} ->
        "Ports"

      {"set_dockerfile", _} ->
        "Update Dockerfile"

      {"set_dev_command", _} ->
        "Set dev command"

      {"add_service", %{"name" => n}} ->
        "Add service #{n}"

      {"add_service", _} ->
        "Add service"

      {"remove_service", %{"name" => n}} ->
        "Remove service #{n}"

      {"remove_service", _} ->
        "Remove service"

      {"set_env_vars", _} ->
        "Set environment"

      {"set_workspace_name", %{"name" => n}} ->
        "Name project #{n}"

      {"set_workspace_name", _} ->
        "Name project"

      {"set_system_prompt", _} ->
        "Set system prompt"

      {"start_services", _} ->
        "Start services"

      {"stop_services", _} ->
        "Stop services"

      {"rebuild", _} ->
        "Rebuild"

      {"service_status", _} ->
        "Service status"

      {"service_containers", _} ->
        "Service containers"

      {"list_secrets", _} ->
        "List secrets"

      {"get_secret", %{"key" => k}} ->
        "Get secret #{k}"

      {"get_secret", _} ->
        "Get secret"

      {"ToolSearch", _} ->
        "Loading tools"

      {"WebSearch", %{"query" => q}} ->
        "Search: #{String.slice(q, 0..60)}"

      {"WebFetch", %{"url" => url}} ->
        "Fetch #{String.slice(url, 0..60)}"

      {name, _} ->
        name |> String.replace("_", " ") |> String.capitalize()
    end
  end

  def summarize(tool_name, _input), do: tool_name
end
