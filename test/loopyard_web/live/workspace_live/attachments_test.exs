defmodule LoopyardWeb.Live.WorkspaceLive.AttachmentsTest do
  @moduledoc """
  A file attached in the composer (paperclip / paste / drop all feed the same
  LiveView upload) lands in the workspace volume and reaches the agent as a
  marker line in the message; the transcript renders it as a thumbnail.
  """
  use LoopyardWeb.ConnCase

  @moduletag timeout: 10_000

  import Phoenix.LiveViewTest

  alias Loopyard.Test.FakeAttachmentWriter

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "loopyard-att-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    ws_dir = Path.join(tmp_dir, ".loopyard/workspace")
    File.mkdir_p!(ws_dir)
    File.write!(Path.join(ws_dir, "docker-compose.yml"), Jason.encode!(%{"services" => %{}}))
    {:ok, _project, ws} = Loopyard.ProjectRegistry.add(tmp_dir)

    agent_id = "att-agent-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      Loopyard.TestHelpers.start_agent(
        id: agent_id,
        name: "Attach Agent",
        working_dir: tmp_dir,
        bind_mount: tmp_dir,
        started_by: "test"
      )

    on_exit(fn ->
      try do
        Loopyard.ChatAgent.stop_agent(agent_id)
      catch
        :exit, _ -> :ok
      end

      Process.sleep(50)
      File.rm_rf!(tmp_dir)
    end)

    %{
      ws: ws,
      agent_id: agent_id,
      path: "/projects/#{ws.project_id}/workspaces/#{ws.id}/agents/#{agent_id}"
    }
  end

  defp last_user_message(agent_id) do
    Loopyard.ChatAgent.get_state(agent_id).messages
    |> Enum.filter(&(&1.role == :user))
    |> List.last()
  end

  test "the composer offers a paperclip, a tray, and a drop target", %{conn: conn, path: path} do
    {:ok, view, html} = live(conn, path)

    assert html =~ ~s(id="chat-attach")
    assert html =~ ~s(phx-hook="ChatAttachments")
    assert html =~ ~s(phx-drop-target=")
    assert has_element?(view, "#chat-attachments input[type=file]")
  end

  test "an uploaded screenshot is stored in the volume and reaches the agent as a marker line",
       %{conn: conn, path: path, ws: ws, agent_id: agent_id} do
    {:ok, view, _html} = live(conn, path)

    shot =
      file_input(view, "#chat-attachments", :attachments, [
        %{name: "Screen Shot.png", content: @png, type: "image/png"}
      ])

    assert render_upload(shot, "Screen Shot.png") =~ "Screen Shot.png"
    # The tray counts it, so the hook lets a text-less Send through.
    assert has_element?(view, "#chat-attachments[data-count='1']")

    assert render_submit(form(view, "#chat-form", %{message: "Why is the header cut off?"})) != ""

    msg = last_user_message(agent_id)

    assert msg.content =~
             "Why is the header cut off?\n\n📎 Attached: /workspace/.loopyard/uploads/"

    assert msg.content =~ ~r/-Screen-Shot\.png \(image\/png, #{byte_size(@png)} bytes\)/

    {_, [att]} = Loopyard.Attachments.parse(msg.content)
    volume = Loopyard.Workspace.volume_name_for(ws.id)
    assert FakeAttachmentWriter.read(volume, att.path) == @png
    assert FakeAttachmentWriter.read(volume, ".loopyard/uploads/.gitignore") == "*\n"

    # The tray is empty again, and the transcript shows the thumbnail via the
    # attachment route — never the raw marker line.
    assert has_element?(view, "#chat-attachments[data-count='0']")
    html = render(view)

    assert html =~
             ~s(src="/projects/#{ws.project_id}/workspaces/#{ws.id}/attachments/#{att.name}")

    refute html =~ "📎 Attached:"
  end

  test "attachments alone are a send — no text required", %{
    conn: conn,
    path: path,
    agent_id: agent_id
  } do
    {:ok, view, _html} = live(conn, path)

    log =
      file_input(view, "#chat-attachments", :attachments, [
        %{name: "server.log", content: "boom\n", type: "text/plain"}
      ])

    render_upload(log, "server.log")
    render_submit(form(view, "#chat-form", %{message: ""}))

    msg = last_user_message(agent_id)

    assert msg.content =~
             ~r/^📎 Attached: \/workspace\/\.loopyard\/uploads\/\S+-server\.log \(text\/plain, 5 bytes\)/
  end

  test "an empty box with an empty tray is still not a send", %{
    conn: conn,
    path: path,
    agent_id: agent_id
  } do
    {:ok, view, _html} = live(conn, path)
    render_submit(form(view, "#chat-form", %{message: "  "}))
    assert last_user_message(agent_id) == nil
  end

  test "a refused (too large) file shows its error, never counts, and never blocks Send", %{
    conn: conn,
    path: path,
    agent_id: agent_id
  } do
    prev = Application.get_env(:loopyard, :attachment_max_bytes)
    Application.put_env(:loopyard, :attachment_max_bytes, 8)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:loopyard, :attachment_max_bytes, prev),
        else: Application.delete_env(:loopyard, :attachment_max_bytes)
    end)

    {:ok, view, _html} = live(conn, path)

    big =
      file_input(view, "#chat-attachments", :attachments, [
        %{name: "big.png", content: @png, type: "image/png"}
      ])

    assert {:error, [[_, :too_large]]} = render_upload(big, "big.png")

    html = render(view)
    assert html =~ "Too large"
    assert has_element?(view, "#chat-attachments[data-count='0']")

    # Send goes through with the text alone; the refused entry is dropped, not
    # reported as "still uploading".
    render_submit(form(view, "#chat-form", %{message: "just words"}))
    assert last_user_message(agent_id).content == "just words"
    refute render(view) =~ "Too large"
  end

  test "a removed chip is not sent", %{conn: conn, path: path, agent_id: agent_id} do
    {:ok, view, _html} = live(conn, path)

    shot =
      file_input(view, "#chat-attachments", :attachments, [
        %{name: "a.png", content: @png, type: "image/png"}
      ])

    render_upload(shot, "a.png")
    assert has_element?(view, "#chat-attachments[data-count='1']")

    view |> element("#chat-attachments button[phx-click='cancel_attachment']") |> render_click()
    assert has_element?(view, "#chat-attachments[data-count='0']")

    render_submit(form(view, "#chat-form", %{message: "no files"}))
    assert last_user_message(agent_id).content == "no files"
  end
end
