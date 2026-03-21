defmodule BoomLooperWeb.OutputController do
  use BoomLooperWeb, :controller

  def show(conn, %{"agent_id" => agent_id, "msg_id" => msg_id}) do
    case BoomLooper.ChatAgent.get_message(agent_id, msg_id) do
      %{content: content} when is_binary(content) ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, content)

      _ ->
        send_resp(conn, 404, "Message not found")
    end
  end

  @doc "Generate a URL for a message (LiveView page)"
  def msg_url(agent_id, msg_id) do
    "/messages/#{agent_id}/#{msg_id}"
  end

  @doc "Generate a URL for raw text content"
  def raw_url(agent_id, msg_id) do
    "/messages/#{agent_id}/#{msg_id}/raw"
  end
end
