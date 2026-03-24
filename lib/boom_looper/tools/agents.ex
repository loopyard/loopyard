defmodule BoomLooper.Tools.Agents do
  @moduledoc """
  Tools for managing BoomLooper agents. Allows an agent to list, spawn,
  message, and stop other agents.
  """
  use ClaudeCode.MCP.Server, name: "boom-looper-agents"

  alias BoomLooper.ChatAgent

  # --- Public API (callable from tests and other modules) ---

  def do_list do
    ChatAgent.list_agents()
    |> Enum.map(fn a ->
      %{id: a.id, name: a.name, status: to_string(a.status), working_dir: a.working_dir}
    end)
  end

  def do_spawn(name, working_dir) do
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    workspace_id = BoomLooper.ProjectRegistry.workspace_id(working_dir)

    case BoomLooper.WorkspaceGroup.start_agent(workspace_id,
           id: id,
           name: name,
           working_dir: working_dir,
           bind_mount: working_dir,
           started_by: "agent"
         ) do
      {:ok, _pid} -> {:ok, %{id: id, name: name}}
      {:error, reason} -> {:error, "Failed to spawn: #{inspect(reason)}"}
    end
  end

  def do_send_message(agent_id, message) do
    case Registry.lookup(BoomLooper.ChatAgentRegistry, agent_id) do
      [{_pid, _}] ->
        ChatAgent.send_message(agent_id, message)
        {:ok, "Message sent to agent #{agent_id}"}
      [] ->
        {:error, "Agent #{agent_id} not found"}
    end
  end

  def do_rename(agent_id, new_name) do
    case Registry.lookup(BoomLooper.ChatAgentRegistry, agent_id) do
      [{_pid, _}] ->
        ChatAgent.rename(agent_id, new_name)
        {:ok, "Agent renamed to #{new_name}"}
      [] ->
        {:error, "Agent #{agent_id} not found"}
    end
  end

  def do_stop(agent_id) do
    case Registry.lookup(BoomLooper.ChatAgentRegistry, agent_id) do
      [{_pid, _}] ->
        ChatAgent.stop_agent(agent_id)
        {:ok, "Agent #{agent_id} stopped"}
      [] ->
        {:error, "Agent #{agent_id} not found"}
    end
  end

  def do_read_chat(agent_id, opts \\ %{}) do
    case ChatAgent.get_state(agent_id) do
      nil ->
        {:error, "Agent #{agent_id} not found"}

      state ->
        messages = state.messages
        tail = Map.get(opts, :tail, 50)

        messages = if length(messages) > tail do
          Enum.take(messages, -tail)
        else
          messages
        end

        formatted = Enum.map_join(messages, "\n", fn msg ->
          role = msg.role |> to_string() |> String.upcase()
          content = (msg[:content] || "") |> String.trim()
          content = if String.length(content) > 500, do: String.slice(content, 0..500) <> "...", else: content
          "[#{role}] #{content}"
        end)

        {:ok, "Chat history for #{state.name} (#{agent_id}):\n\n#{formatted}"}
    end
  end

  # --- Tool definitions (SDK interface) ---

  tool :list_agents, "List all running agents with their IDs, names, and status" do
    def execute(_params) do
      {:ok, BoomLooper.Tools.Agents.do_list()}
    end
  end

  tool :spawn_agent, "Spawn a new agent with a name and working directory" do
    field :name, :string, required: true
    field :working_dir, :string, required: true

    def execute(%{name: name, working_dir: working_dir}) do
      BoomLooper.Tools.Agents.do_spawn(name, working_dir)
    end
  end

  tool :send_message_to_agent, "Send a message to another agent" do
    field :agent_id, :string, required: true
    field :message, :string, required: true

    def execute(%{agent_id: agent_id, message: message}) do
      BoomLooper.Tools.Agents.do_send_message(agent_id, message)
    end
  end

  tool :rename_agent, "Rename an agent. Use your own agent_id to rename yourself." do
    field :agent_id, :string, required: true
    field :name, :string, required: true

    def execute(%{agent_id: agent_id, name: name}) do
      BoomLooper.Tools.Agents.do_rename(agent_id, name)
    end
  end

  tool :read_agent_chat, "Read another agent's chat history. Use this to see what happened in another agent's session, debug errors, or understand context." do
    field :agent_id, :string, required: true
    field :tail, :integer, required: false, description: "Number of recent messages to return (default: 50)"

    def execute(%{agent_id: agent_id} = params) do
      BoomLooper.Tools.Agents.do_read_chat(agent_id, params)
    end
  end

  tool :stop_agent, "Stop a running agent" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Agents.do_stop(agent_id)
    end
  end
end
