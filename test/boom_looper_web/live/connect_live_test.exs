defmodule BoomLooperWeb.ConnectLiveTest do
  use BoomLooperWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders QR code and URL", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/connect")
      assert html =~ "Scan to open on your phone"
      assert html =~ "http://"
      assert html =~ "Copy"
    end

    test "shows same Wi-Fi note", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/connect")
      assert html =~ "Same Wi-Fi"
    end

    test "mount returns under 500ms — only one local ipconfig shell-out", %{conn: conn} do
      {micros, {:ok, _view, _html}} = :timer.tc(fn -> live(conn, "/connect") end)
      assert micros < 500_000,
        "ConnectLive mount took #{div(micros, 1000)}ms — slow call slipped in"
    end
  end
end
