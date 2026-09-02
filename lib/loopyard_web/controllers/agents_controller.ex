defmodule LoopyardWeb.AgentsController do
  @moduledoc """
  `/operator` → the identity's default system agent's page (`/agents/:id`),
  creating it on the first ever visit. A controller, not a LiveView: the
  first visit may boot a workstation container, which a LiveView mount must
  never wait on.
  """
  use LoopyardWeb, :controller

  alias Loopyard.Agents

  def operator(conn, _params) do
    id =
      Agents.default_id() ||
        case Agents.ensure_default() do
          {:ok, %{agent_id: id}} -> id
          _ -> nil
        end

    if id do
      redirect(conn, to: "/agents/#{id}")
    else
      conn
      |> put_flash(
        :error,
        "The operator couldn't start — check the workstation container on /system."
      )
      |> redirect(to: "/")
    end
  end
end
