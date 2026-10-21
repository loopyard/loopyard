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

  Both are casts; the `StatusChanged` broadcast refreshes the row.
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

  @doc ~S|`set_agent_workstation` event: `%{"workstation" => id, "agent-id" => id}`.|
  def set_workstation(%{"workstation" => ws_id} = params, socket) do
    agent_id = params["agent-id"] || socket.assigns.selected_id

    if is_binary(agent_id) and is_binary(ws_id) and ws_id != "" do
      ChatAgent.set_workstation(agent_id, ws_id)
    end

    {:noreply, socket}
  end
end
