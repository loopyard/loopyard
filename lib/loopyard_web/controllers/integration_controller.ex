defmodule LoopyardWeb.IntegrationController do
  @moduledoc """
  Serves an integration's doc as raw markdown — the same source the per-tool page
  renders, so an **agent** can fetch `/workstations/:id/:tool/docs.md` and read how
  to wire a tool into the box (then do it, or walk the user through it). The doc is
  identity-agnostic; the `:id` just scopes the URL + fills the `$WS` placeholder.
  """
  use LoopyardWeb, :controller

  alias Loopyard.Workstation.Integration

  def doc(conn, %{"id" => ws, "tool" => tool}) do
    case Integration.doc(tool) do
      {:ok, md} ->
        # Agent-facing: $LOOPYARD → this server; $WS → the workstation in the URL,
        # so the curl examples name the identity the agent fetched the doc for.
        body =
          md
          |> String.replace("$LOOPYARD", base_url(conn))
          |> String.replace("$WS", ws)

        conn
        |> put_resp_content_type("text/markdown")
        |> send_resp(200, body)

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "no such integration: #{tool}\n")
    end
  end

  defp base_url(conn) do
    proto =
      case get_req_header(conn, "x-forwarded-proto") do
        [p | _] -> p
        _ -> to_string(conn.scheme)
      end

    host =
      case get_req_header(conn, "host") do
        [h | _] -> h
        _ -> "#{conn.host}:#{conn.port}"
      end

    "#{proto}://#{host}"
  end
end
