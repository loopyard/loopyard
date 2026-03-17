defmodule Hive.Tools.Agents do
  @moduledoc """
  Tools for managing Hive agents. Allows an agent to list, spawn,
  message, and stop other agents.
  """
  use ClaudeCode.MCP.Server, name: "hive-agents"

  alias Hive.ChatAgent

  # --- Public API (callable from tests and other modules) ---

  def do_list do
    ChatAgent.list_agents()
    |> Enum.map(fn a ->
      %{id: a.id, name: a.name, status: to_string(a.status), working_dir: a.working_dir}
    end)
  end

  def do_spawn(name, working_dir) do
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    case Hive.ChatAgentSupervisor.start_agent(
           id: id,
           name: name,
           working_dir: working_dir,
           started_by: "agent"
         ) do
      {:ok, _pid} -> {:ok, %{id: id, name: name}}
      {:error, reason} -> {:error, "Failed to spawn: #{inspect(reason)}"}
    end
  end

  def do_send_message(agent_id, message) do
    case Registry.lookup(Hive.ChatAgentRegistry, agent_id) do
      [{_pid, _}] ->
        ChatAgent.send_message(agent_id, message)
        {:ok, "Message sent to agent #{agent_id}"}
      [] ->
        {:error, "Agent #{agent_id} not found"}
    end
  end

  def do_stop(agent_id) do
    case Registry.lookup(Hive.ChatAgentRegistry, agent_id) do
      [{_pid, _}] ->
        ChatAgent.stop_agent(agent_id)
        {:ok, "Agent #{agent_id} stopped"}
      [] ->
        {:error, "Agent #{agent_id} not found"}
    end
  end

  # --- Tool definitions (SDK interface) ---

  tool :list_agents, "List all running agents with their IDs, names, and status" do
    def execute(_params) do
      {:ok, Hive.Tools.Agents.do_list()}
    end
  end

  tool :spawn_agent, "Spawn a new agent with a name and working directory" do
    field :name, :string, required: true
    field :working_dir, :string, required: true

    def execute(%{name: name, working_dir: working_dir}) do
      Hive.Tools.Agents.do_spawn(name, working_dir)
    end
  end

  tool :send_message_to_agent, "Send a message to another agent" do
    field :agent_id, :string, required: true
    field :message, :string, required: true

    def execute(%{agent_id: agent_id, message: message}) do
      Hive.Tools.Agents.do_send_message(agent_id, message)
    end
  end

  tool :stop_agent, "Stop a running agent" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      Hive.Tools.Agents.do_stop(agent_id)
    end
  end
end
