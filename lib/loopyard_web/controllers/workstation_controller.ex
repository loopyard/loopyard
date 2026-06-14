defmodule LoopyardWeb.WorkstationController do
  @moduledoc """
  Switch the **current identity** (the workstation you operate as) and create
  new ones. Mutates the global `Loopyard.Workstation.current/0` — a file, not a
  browser session — so `mix loopyard.rpc` and agent tool calls see the same
  current identity the UI does. That's deliberate: one driver at a time on a
  single-user box, and headless smoke tests need to set/read it too.
  """
  use LoopyardWeb, :controller

  alias Loopyard.Workstation

  @doc "Switch the current identity, then bounce back to where you came from."
  def switch(conn, %{"id" => id}) do
    case Workstation.set_current(id) do
      :ok ->
        conn
        |> put_flash(:info, "Now operating as #{id}.")
        |> redirect(to: back_path(conn))

      {:error, _} ->
        conn
        |> put_flash(:error, "No such workstation: #{id}.")
        |> redirect(to: "/workstation")
    end
  end

  @doc "Create a new identity (seeds its Dockerfile) and switch to it."
  def create(conn, %{"ws_id" => raw}) do
    id = raw |> to_string() |> String.trim()

    case Workstation.create(id) do
      :ok ->
        _ = Workstation.set_current(id)

        conn
        |> put_flash(:info, "Created #{id} — you're now operating as it.")
        |> redirect(to: "/workstation")

      {:error, :exists} ->
        _ = Workstation.set_current(id)
        redirect(conn, to: "/workstation")

      {:error, :invalid_id} ->
        conn
        |> put_flash(:error, "Invalid id (lowercase letters, digits, dashes; ≤39 chars).")
        |> redirect(to: "/workstation")
    end
  end

  # Prefer the referer so switching from any page returns you there; fall back to
  # the Workstation page.
  defp back_path(conn) do
    case get_req_header(conn, "referer") do
      [ref | _] -> safe_path(ref)
      _ -> "/workstation"
    end
  end

  # Only honor same-origin path-only referers (avoid open-redirect).
  defp safe_path(ref) do
    case URI.parse(ref) do
      %URI{path: p} when is_binary(p) and p != "" -> p
      _ -> "/workstation"
    end
  end
end
