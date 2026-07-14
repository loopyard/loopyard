defmodule LoopyardWeb.OperatorLive do
  @moduledoc """
  `/operator` — opens the operating identity's operator agent, creating it on
  first visit. A thin redirect: ensure the agent (`Loopyard.Operator.ensure_agent/0`),
  then live-navigate to its chat (the normal agent view). The agent lives in a
  hidden reserved workspace, so this route is the door to it.
  """
  use LoopyardWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      case Loopyard.Operator.ensure_agent() do
        {:ok, %{project_id: pid, workspace_id: ws_id, agent_id: aid}} ->
          {:ok, push_navigate(socket, to: "/projects/#{pid}/workspaces/#{ws_id}/agents/#{aid}")}

        _ ->
          {:ok, socket |> put_flash(:error, "Couldn't start the operator agent.") |> push_navigate(to: "/")}
      end
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center text-sm text-zinc-400 dark:text-zinc-500">
      Opening the operator…
    </div>
    """
  end
end
