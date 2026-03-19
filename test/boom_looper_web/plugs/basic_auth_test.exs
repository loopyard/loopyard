defmodule BoomLooperWeb.Plugs.BasicAuthTest do
  use BoomLooperWeb.ConnCase

  alias BoomLooperWeb.Plugs.BasicAuth

  describe "when no password is configured" do
    setup do
      original = Application.get_env(:boom_looper, :auth_password)
      Application.put_env(:boom_looper, :auth_password, nil)
      on_exit(fn -> Application.put_env(:boom_looper, :auth_password, original) end)
      :ok
    end

    test "allows all requests through", %{conn: conn} do
      conn = BasicAuth.call(conn, [])
      refute conn.halted
    end
  end

  describe "when password is configured" do
    setup do
      original_pw = Application.get_env(:boom_looper, :auth_password)
      original_user = Application.get_env(:boom_looper, :auth_username)
      Application.put_env(:boom_looper, :auth_password, "secret123")
      Application.put_env(:boom_looper, :auth_username, nil)

      on_exit(fn ->
        Application.put_env(:boom_looper, :auth_password, original_pw)
        Application.put_env(:boom_looper, :auth_username, original_user)
      end)

      :ok
    end

    test "rejects requests without credentials", %{conn: conn} do
      conn = BasicAuth.call(conn, [])
      assert conn.halted
      assert conn.status == 401
    end

    test "accepts requests with correct password (any username)", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", basic_auth("anyuser", "secret123"))
        |> BasicAuth.call([])

      refute conn.halted
    end

    test "rejects requests with wrong password", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", basic_auth("anyuser", "wrongpassword"))
        |> BasicAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "when username and password are configured" do
    setup do
      original_pw = Application.get_env(:boom_looper, :auth_password)
      original_user = Application.get_env(:boom_looper, :auth_username)
      Application.put_env(:boom_looper, :auth_password, "secret123")
      Application.put_env(:boom_looper, :auth_username, "admin")

      on_exit(fn ->
        Application.put_env(:boom_looper, :auth_password, original_pw)
        Application.put_env(:boom_looper, :auth_username, original_user)
      end)

      :ok
    end

    test "accepts correct username and password", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", basic_auth("admin", "secret123"))
        |> BasicAuth.call([])

      refute conn.halted
    end

    test "rejects wrong username", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", basic_auth("notadmin", "secret123"))
        |> BasicAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end
  end

  defp basic_auth(username, password) do
    "Basic " <> Base.encode64("#{username}:#{password}")
  end
end
