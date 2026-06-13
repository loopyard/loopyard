defmodule LoopyardWeb.OpenUrlController do
  @moduledoc """
  Receives "open this URL in the browser" requests from inside containers — the
  `$BROWSER`/`xdg-open` shim (see `Loopyard.Workstation.OpenBridge`) POSTs here
  when a device-flow login wants a browser. We validate the per-install token,
  then broadcast the URL to the Workstation page, which pops a one-tap Open
  button.

  Token-gated because this route is reachable over the public quick-tunnel.
  Only `http`/`https` URLs are forwarded.
  """
  use LoopyardWeb, :controller

  alias Loopyard.{Events, Token}

  def create(conn, params) do
    token = get_token(conn, params)

    cond do
      not Token.has_grant?(token, :open_url) ->
        conn |> put_status(:forbidden) |> json(%{error: "missing open_url grant"})

      not valid_url?(params["url"]) ->
        conn |> put_status(:bad_request) |> json(%{error: "bad url"})

      true ->
        Events.Workstation.publish(%Events.Workstation.OpenUrl{url: params["url"]})
        send_resp(conn, :no_content, "")
    end
  end

  defp get_token(conn, params) do
    case get_req_header(conn, "x-loopyard-token") do
      [t | _] -> t
      _ -> params["token"]
    end
  end

  defp valid_url?(url) when is_binary(url),
    do: String.starts_with?(url, "http://") or String.starts_with?(url, "https://")

  defp valid_url?(_), do: false
end
