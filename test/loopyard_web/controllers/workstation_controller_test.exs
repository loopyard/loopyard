defmodule LoopyardWeb.WorkstationControllerTest do
  # async: false — isolates LOOPYARD_HOME (a global) for on-disk workstation state.
  use LoopyardWeb.ConnCase, async: false

  alias Loopyard.Workstation

  setup do
    Loopyard.StateKeeper.ensure_tables!()

    prev = System.get_env("LOOPYARD_HOME")
    tmp = Path.join(System.tmp_dir!(), "loopyard-test-#{System.unique_integer([:positive])}")
    System.put_env("LOOPYARD_HOME", tmp)

    on_exit(fn ->
      if prev, do: System.put_env("LOOPYARD_HOME", prev), else: System.delete_env("LOOPYARD_HOME")
      File.rm_rf(tmp)
    end)

    :ok
  end

  describe "bare URL redirects to the current workstation" do
    test "GET /workstation → /workstations/<current>", %{conn: conn} do
      conn = get(conn, "/workstation")
      assert redirected_to(conn) =~ ~r{^/workstations/[a-z0-9-]+$}
    end

    test "GET /workstations → /workstations/<current>", %{conn: conn} do
      conn = get(conn, "/workstations")
      assert redirected_to(conn) =~ ~r{^/workstations/[a-z0-9-]+$}
    end
  end

  describe "credential push endpoints name a real workstation" do
    test "setup.sh serves the script for an existing workstation, baking its id in", %{conn: conn} do
      :ok = Workstation.create("brad")

      conn = get(conn, "/workstations/brad/setup.sh")

      assert conn.status == 200
      assert conn.resp_body =~ ~s(WS="brad")
      assert conn.resp_body =~ "/workstations/$WS/env/"
    end

    test "setup.sh 404s for an unknown workstation", %{conn: conn} do
      conn = get(conn, "/workstations/nope-xyz/setup.sh")
      assert conn.status == 404
    end

    test "env push 404s for an unknown workstation", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put("/workstations/nope-xyz/env/FOO", "value")

      assert conn.status == 404
    end

    test "env push stores the value for an existing workstation", %{conn: conn} do
      :ok = Workstation.create("brad")

      conn =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put("/workstations/brad/env/MY_TOKEN", "s3cr3t")

      assert conn.status == 204
      assert Loopyard.Workstation.Env.all("brad")["MY_TOKEN"] == "s3cr3t"
    end
  end
end
