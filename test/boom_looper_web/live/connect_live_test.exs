defmodule BoomLooperWeb.ConnectLiveTest do
  use BoomLooperWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders exposure toggle or QR depending on state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/connect")

      if BoomLooper.HostExposer.exposed?() do
        assert html =~ "Scan to open on your phone"
        assert html =~ "http://"
        assert html =~ "Stop exposing"
      else
        assert html =~ "Remote access"
        assert html =~ "Expose endpoint"
      end
    end

    test "mount returns under 500ms", %{conn: conn} do
      {micros, {:ok, _view, _html}} = :timer.tc(fn -> live(conn, "/connect") end)
      assert micros < 500_000,
        "ConnectLive mount took #{div(micros, 1000)}ms — slow call slipped in"
    end
  end
end
