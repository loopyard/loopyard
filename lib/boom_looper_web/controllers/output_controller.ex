defmodule BoomLooperWeb.OutputController do
  use BoomLooperWeb, :controller

  # Signed URLs expire after 1 hour
  @max_age 3600

  def show(conn, %{"id" => agent_id, "index" => index_str, "token" => token}) do
    expected = "#{agent_id}:#{index_str}"

    case Phoenix.Token.verify(BoomLooperWeb.Endpoint, "msg", token, max_age: @max_age) do
      {:ok, ^expected} ->
        serve_message(conn, agent_id, String.to_integer(index_str))

      _ ->
        send_resp(conn, 403, "Link expired or invalid")
    end
  end

  def show(conn, _params) do
    send_resp(conn, 403, "Missing token")
  end

  @doc "Generate a signed URL for a message (LiveView page)"
  def signed_url(workspace_id, agent_id, index) do
    token = Phoenix.Token.sign(BoomLooperWeb.Endpoint, "msg", "#{agent_id}:#{index}")
    "/p/#{workspace_id}/b/#{workspace_id}/chat/#{agent_id}/msg/#{index}?token=#{token}"
  end

  @doc "Generate a signed URL for raw text content (for clipboard)"
  def raw_url(workspace_id, agent_id, index) do
    token = Phoenix.Token.sign(BoomLooperWeb.Endpoint, "msg", "#{agent_id}:#{index}")
    "/p/#{workspace_id}/b/#{workspace_id}/chat/#{agent_id}/msg/#{index}/raw?token=#{token}"
  end

  defp serve_message(conn, agent_id, index) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{messages: messages} when is_list(messages) ->
        case Enum.at(messages, index) do
          %{content: content} when is_binary(content) ->
            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(200, content)

          _ ->
            send_resp(conn, 404, "Message not found")
        end

      _ ->
        send_resp(conn, 404, "Agent not found")
    end
  end
end
