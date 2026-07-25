defmodule LoopyardWeb.OutputController do
  use LoopyardWeb, :controller

  # Raw text mirrors what the permalink shows: a TURN (user prompt) appends the
  # whole exchange — prompt through result — into one plain-text blob you can
  # copy or feed to another tool; a SINGLE message returns just its content.
  def show(conn, %{"agent_id" => agent_id, "msg_id" => msg_id}) do
    case LoopyardWeb.TurnSlice.resolve(agent_id, msg_id) do
      {_mode, [], _anchor} ->
        send_resp(conn, 404, "Message not found")

      {_mode, msgs, _anchor} ->
        text =
          msgs
          |> Enum.map(& &1[:content])
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.join("\n\n")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, text)
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
