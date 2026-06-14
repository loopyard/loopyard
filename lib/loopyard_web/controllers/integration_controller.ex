defmodule LoopyardWeb.IntegrationController do
  @moduledoc """
  Serves an integration's doc as raw markdown — the same source the per-tool page
  renders, so an **agent** can fetch `/workstation/:tool/docs.md` and read how to
  wire a tool into the box (then do it, or walk the user through it).
  """
  use LoopyardWeb, :controller

  alias Loopyard.Workstation.Integration

  def doc(conn, %{"tool" => tool}) do
    case Integration.doc(tool) do
      {:ok, md} ->
        conn
        |> put_resp_content_type("text/markdown")
        |> send_resp(200, String.replace(md, "$LOOPYARD", base_url(conn)))

      {:error, :not_found} ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "no such integration: #{tool}\n")
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
