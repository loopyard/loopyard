defmodule LoopyardWeb.WorkstationController do
  @moduledoc """
  Bare-URL redirect to the current identity's page, and creating new identities.
  Each workstation lives at its own URL (`/workstations/:id`); *visiting* one makes
  it the one you're operating as. The "current" identity (a file, not a browser
  session) is what bare `/workstation(s)` resolves to and what new agents inherit.
  """
  use LoopyardWeb, :controller

  alias Loopyard.Workstation

  @doc "Bare /workstation(s) → the page for the identity you're operating as."
  def index(conn, _params) do
    redirect(conn, to: "/workstations/#{Workstation.current()}")
  end

  @doc "Create a new identity (seeds its build context) and go operate as it."
  def create(conn, %{"ws_id" => raw}) do
    id = raw |> to_string() |> String.trim()

    case Workstation.create(id) do
      :ok ->
        conn
        |> put_flash(:info, "Created #{id} — you're now operating as it.")
        |> redirect(to: "/workstations/#{id}")

      {:error, :exists} ->
        redirect(conn, to: "/workstations/#{id}")

      {:error, :invalid_id} ->
        conn
        |> put_flash(:error, "Invalid id (lowercase letters, digits, dashes; ≤39 chars).")
        |> redirect(to: "/workstations/#{Workstation.current()}")
    end
  end
end
