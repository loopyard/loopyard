defmodule LoopyardWeb.Live.WorkspaceLive.AgentPicker do
  @moduledoc """
  The Usage panel's two pickers, as `handle_event` bodies for `WorkspaceLive`
  (extracted to keep that file under its size cap):

    * **harness + model** — one `harness:model` token
      (`Harness.Catalog.parse_selection/1`), so "run this on Codex" is the same
      gesture as "run this on Opus 4.8". Same harness → live ACP
      `session/set_model`, no restart; different harness → restart onto the new
      adapter, conversation carried over from Loopyard's durable log.
    * **account** — which workstation's credentials the harness signs in with.
      The agent re-stamps itself and runs a `:credentials` restart
      (conversation carried over, native session dropped).

    * **sub-agents** — which model the harness's OWN sub-agents run on
      (`ChatAgent.SubagentControl`); "" is "Same as the agent". Relaunches the
      harness when idle, conversation resumed.

  Plus the composer's **Discuss / Build** switch (`set_mode/2`) — the same
  shape: server state on the agent (`ChatAgent.ModeControl`), persisted.

  All are casts; the `StatusChanged` broadcast refreshes every viewer's
  control — nothing is assumed locally.
  """

  alias Loopyard.ChatAgent
  alias Loopyard.Harness.Catalog

  @doc ~S|`set_agent_model` event: `%{"model" => "harness:model", "agent-id" => id}`.|
  def set_model(%{"model" => selection} = params, socket) do
    agent_id = params["agent-id"] || socket.assigns.selected_id

    with true <- is_binary(agent_id),
         {:ok, harness, model} <- Catalog.parse_selection(selection) do
      agent = Enum.find(socket.assigns.agents, &(&1.id == agent_id)) || %{}
      current = agent[:harness] || Catalog.default()

      if harness == current do
        if model, do: ChatAgent.set_model(agent_id, model)
      else
        ChatAgent.set_harness(agent_id, harness, model)
      end
    end

    {:noreply, socket}
  end

  # Not a workstation id (ids are `[a-z0-9-]`), so it can never collide.
  @add_account "+"

  @doc "The Account picker's \"Add an account…\" option value."
  def add_account_value, do: @add_account

  @doc ~S|`set_agent_workstation` event: `%{"workstation" => id, "agent-id" => id}`.|
  def set_workstation(%{"workstation" => @add_account}, socket),
    do: {:noreply, Phoenix.LiveView.push_navigate(socket, to: "/workstations")}

  def set_workstation(%{"workstation" => ws_id} = params, socket) do
    agent_id = params["agent-id"] || socket.assigns.selected_id

    if is_binary(agent_id) and is_binary(ws_id) and ws_id != "" do
      ChatAgent.set_workstation(agent_id, ws_id)
    end

    {:noreply, socket}
  end

  @doc ~S|`set_subagents` event: `%{"subagent_model" => model or "", "agent-id" => id}`.|
  def set_subagents(%{"subagent_model" => model} = params, socket) when is_binary(model) do
    agent_id = params["agent-id"] || socket.assigns.selected_id
    if is_binary(agent_id), do: ChatAgent.set_subagent_model(agent_id, model)
    {:noreply, socket}
  end

  def set_subagents(_params, socket), do: {:noreply, socket}

  @doc ~S(`set_agent_mode` event: `%{"mode" => "discuss" or "build", "id" => id}`.)
  def set_mode(%{"mode" => mode} = params, socket) do
    agent_id = params["id"] || socket.assigns.selected_id

    with true <- is_binary(agent_id),
         {:ok, setting} <- ChatAgent.ModeControl.parse(mode) do
      ChatAgent.set_mode(agent_id, setting)
    end

    {:noreply, socket}
  end

  def set_mode(_params, socket), do: {:noreply, socket}
end
