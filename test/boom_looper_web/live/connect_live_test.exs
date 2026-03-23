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
  end
end
