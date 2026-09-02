defmodule LoopyardWeb.AttachmentControllerTest do
  use LoopyardWeb.ConnCase, async: true

  alias Loopyard.Test.FakeVolumeIO

  @ws "att-ctl-ws"
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>

  setup do
    prev = Application.get_env(:loopyard, :volume_reader)
    Application.put_env(:loopyard, :volume_reader, FakeVolumeIO)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:loopyard, :volume_reader, prev),
        else: Application.delete_env(:loopyard, :volume_reader)
    end)

    volume = Loopyard.Workspace.volume_name_for(@ws)
    FakeVolumeIO.seed(volume, [{".loopyard/uploads/20260901T120000-ab12-shot.png", @png}])
    :ok
  end

  test "serves a stored attachment inline with its image content type", %{conn: conn} do
    conn = get(conn, "/projects/p1/workspaces/#{@ws}/attachments/20260901T120000-ab12-shot.png")

    assert conn.status == 200
    assert conn.resp_body == @png
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert [disp] = get_resp_header(conn, "content-disposition")
    assert disp =~ "inline"
    assert [cache] = get_resp_header(conn, "cache-control")
    assert cache =~ "immutable"
  end

  test "the operator's attachments are served out of its workstation container", %{conn: conn} do
    {:container, container, home} = Loopyard.Operator.attachment_target()

    Loopyard.Test.FakeContainerIO.seed(
      container,
      "#{home}/.loopyard/uploads/20260901T1-ab-op.png",
      @png
    )

    conn = get(conn, "/operator/attachments/20260901T1-ab-op.png")
    assert conn.status == 200
    assert conn.resp_body == @png
    assert get_resp_header(conn, "content-type") == ["image/png"]

    assert get(build_conn(), "/operator/attachments/..%2F.ssh%2Fid_rsa").status == 404
  end

  test "an unknown name is a 404, not an error page", %{conn: conn} do
    conn = get(conn, "/projects/p1/workspaces/#{@ws}/attachments/nope.png")
    assert conn.status == 404
  end

  test "dotfiles and traversal-shaped names never reach the volume", %{conn: conn} do
    # The .gitignore in the uploads dir is a real file but not an attachment.
    FakeVolumeIO.seed(Loopyard.Workspace.volume_name_for(@ws), [
      {".loopyard/uploads/.gitignore", "*\n"}
    ])

    assert get(conn, "/projects/p1/workspaces/#{@ws}/attachments/.gitignore").status == 404

    assert get(conn, "/projects/p1/workspaces/#{@ws}/attachments/..%2Frepo%2Fworkspace.json").status ==
             404
  end
end
