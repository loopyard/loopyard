defmodule BoomLooperWeb.Plugs.BasicAuth do
  @moduledoc """
  Simple HTTP Basic Auth plug. Enabled when BOOM_LOOPER_AUTH_PASSWORD is set.
  Username can be anything (or set BOOM_LOOPER_AUTH_USERNAME for a specific one).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_password() do
      nil ->
        # No password configured, skip auth
        conn

      password ->
        username = get_username()

        case Plug.BasicAuth.parse_basic_auth(conn) do
          {^username, ^password} ->
            conn

          {_, ^password} when username == :any ->
            conn

          _ ->
            conn
            |> Plug.BasicAuth.request_basic_auth(realm: "BoomLooper")
            |> halt()
        end
    end
  end

  defp get_password do
    Application.get_env(:boom_looper, :auth_password)
  end

  defp get_username do
    case Application.get_env(:boom_looper, :auth_username) do
      nil -> :any
      "" -> :any
      username -> username
    end
  end
end
