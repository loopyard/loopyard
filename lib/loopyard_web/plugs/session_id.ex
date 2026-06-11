defmodule LoopyardWeb.Plugs.SessionId do
  @moduledoc """
  Stamp a stable per-browser session id into the signed session cookie, so
  per-session server-side state (`Loopyard.Session.Tracker`) has a durable key
  across LiveView mounts/navigations within the same browser.
  """
  import Plug.Conn

  @key "lyd_session_id"

  @doc "The session map key under which the id is stored."
  def key, do: @key

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, @key) do
      nil -> put_session(conn, @key, gen())
      _ -> conn
    end
  end

  defp gen, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end
