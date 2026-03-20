defmodule BoomLooperWeb.LaunchControllerTest do
  use BoomLooperWeb.ConnCase

  setup do
    BoomLooper.ProjectRegistry.ensure_ets_tables()
    BoomLooper.ProjectRegistry.list_projects() |> Enum.each(&BoomLooper.ProjectRegistry.remove_project(&1.id))
    :ok
  end

  describe "launch/2" do
    test "redirects to branch view for valid path with config", %{conn: conn} do
      secret = Application.get_env(:boom_looper, :launch_secret)
      # Use cwd which is a git repo with .hive config potentially
      path = File.cwd!()

      conn = get(conn, "/launch/#{secret}?path=#{URI.encode(path)}")
      assert redirected_to(conn) =~ "/p/"
    end

    test "returns 403 for invalid secret", %{conn: conn} do
      conn = get(conn, "/launch/bad-secret?path=/tmp")
      assert response(conn, 403) =~ "Invalid secret"
    end

    test "returns 400 for missing path", %{conn: conn} do
      secret = Application.get_env(:boom_looper, :launch_secret)
      conn = get(conn, "/launch/#{secret}")
      assert response(conn, 400) =~ "Missing path"
    end

    test "returns 400 for non-existent path", %{conn: conn} do
      secret = Application.get_env(:boom_looper, :launch_secret)
      conn = get(conn, "/launch/#{secret}?path=/no/such/dir/#{:rand.uniform(100_000)}")
      assert response(conn, 400) =~ "Failed"
    end
  end
end
