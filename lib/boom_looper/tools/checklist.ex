defmodule BoomLooper.Tools.Checklist do
  @moduledoc """
  MCP tool server for checklist operations.

  Agents use these tools to list available checklists, start one,
  track progress, and check/uncheck items. Changes are broadcast
  via PubSub so the context panel updates in real-time.
  """
  use ClaudeCode.MCP.Server, name: "boom-looper-checklist"

  alias BoomLooper.Checklist

  @topic "chat_agents"

  # --- Public API ---

  def do_list_checklists(project_dir) do
    Checklist.available(project_dir)
    |> Enum.map(fn c ->
      %{id: c.id, name: c.name, description: c.description}
    end)
  end

  def do_start_checklist(agent_id, checklist_id) do
    case find_project_dir(agent_id) do
      {:ok, project_dir} ->
        case Checklist.instantiate_by_id(checklist_id, agent_id, project_dir) do
          {:ok, checklist} ->
            broadcast_checklist_updated(agent_id, checklist.active_path)
            {:ok, %{active_path: checklist.active_path, name: checklist.name, items: checklist.items}}

          {:error, :not_found} ->
            {:error, "Checklist '#{checklist_id}' not found. Use list_checklists to see available checklists."}
        end

      :error ->
        {:error, "Agent #{agent_id} has no bind mount"}
    end
  end

  def do_get_progress(agent_id) do
    case find_active_checklist(agent_id) do
      {:ok, path} ->
        case Checklist.load_file(path) do
          {:ok, checklist} ->
            {checked, total} = Checklist.progress(checklist)
            {:ok, %{checked: checked, total: total, items: checklist.items, path: path}}

          {:error, reason} ->
            {:error, "Failed to read checklist: #{inspect(reason)}"}
        end

      :not_found ->
        {:error, "No active checklist for this agent. Use start_checklist first."}
    end
  end

  def do_check_item(agent_id, line) do
    case find_active_checklist(agent_id) do
      {:ok, path} ->
        case Checklist.check_item(path, line) do
          :ok ->
            broadcast_checklist_updated(agent_id, path)
            {:ok, "Item at line #{line} checked"}

          {:error, reason} ->
            {:error, "Failed to check item: #{inspect(reason)}"}
        end

      :not_found ->
        {:error, "No active checklist for this agent."}
    end
  end

  def do_uncheck_item(agent_id, line) do
    case find_active_checklist(agent_id) do
      {:ok, path} ->
        case Checklist.uncheck_item(path, line) do
          :ok ->
            broadcast_checklist_updated(agent_id, path)
            {:ok, "Item at line #{line} unchecked"}

          {:error, reason} ->
            {:error, "Failed to uncheck item: #{inspect(reason)}"}
        end

      :not_found ->
        {:error, "No active checklist for this agent."}
    end
  end

  # --- Tool definitions ---

  tool :list_checklists, "List available checklist templates (built-in + project-specific)" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      case BoomLooper.Tools.Checklist.find_project_dir(agent_id) do
        {:ok, project_dir} -> {:ok, BoomLooper.Tools.Checklist.do_list_checklists(project_dir)}
        :error -> {:ok, BoomLooper.Tools.Checklist.do_list_checklists(nil)}
      end
    end
  end

  tool :start_checklist, "Start a checklist by copying a template to the active directory. Returns the active file path and items." do
    field :agent_id, :string, required: true
    field :checklist_id, :string, required: true, description: "The checklist ID (e.g. 'setup', 'feature')"

    def execute(%{agent_id: agent_id, checklist_id: checklist_id}) do
      BoomLooper.Tools.Checklist.do_start_checklist(agent_id, checklist_id)
    end
  end

  tool :get_progress, "Get the current progress of the active checklist" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Checklist.do_get_progress(agent_id)
    end
  end

  tool :check_item, "Mark a checklist item as done by line number" do
    field :agent_id, :string, required: true
    field :line, :integer, required: true, description: "The line number of the item to check (1-based)"

    def execute(%{agent_id: agent_id, line: line}) do
      BoomLooper.Tools.Checklist.do_check_item(agent_id, line)
    end
  end

  tool :uncheck_item, "Unmark a checklist item by line number" do
    field :agent_id, :string, required: true
    field :line, :integer, required: true, description: "The line number of the item to uncheck (1-based)"

    def execute(%{agent_id: agent_id, line: line}) do
      BoomLooper.Tools.Checklist.do_uncheck_item(agent_id, line)
    end
  end

  # --- Helpers (public for tool execute callbacks) ---

  def find_project_dir(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{bind_mount: dir} when is_binary(dir) -> {:ok, dir}
      %{working_dir: dir} when is_binary(dir) -> {:ok, dir}
      _ -> :error
    end
  end

  def find_active_checklist(agent_id) do
    case find_project_dir(agent_id) do
      {:ok, project_dir} ->
        active_dir = Path.join(project_dir, ".boomlooper/workspace/active")

        case File.ls(active_dir) do
          {:ok, files} ->
            case Enum.find(files, &String.starts_with?(&1, "#{agent_id}-")) do
              nil -> :not_found
              file -> {:ok, Path.join(active_dir, file)}
            end

          {:error, _} ->
            :not_found
        end

      :error ->
        :not_found
    end
  end

  defp broadcast_checklist_updated(agent_id, path) do
    case Checklist.load_file(path) do
      {:ok, checklist} ->
        {checked, total} = Checklist.progress(checklist)

        Phoenix.PubSub.broadcast(
          BoomLooper.PubSub,
          @topic,
          {:checklist_updated, agent_id, %{checked: checked, total: total, items: checklist.items}}
        )

      _ ->
        :ok
    end
  end
end
