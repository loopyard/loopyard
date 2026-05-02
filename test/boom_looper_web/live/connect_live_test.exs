defmodule BoomLooperWeb.ConnectLiveTest do
  use BoomLooperWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders exposure toggle or QR depending on state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/remote")

      if BoomLooper.HostExposer.exposed?() do
        assert html =~ "Scan to open on your phone"
        assert html =~ "http://"
        assert html =~ "Stop exposing"
      else
        assert html =~ "Remote access"
        assert html =~ "Expose endpoint"
      end
    end

    test "mount returns under 1s", %{conn: conn} do
      # Warm up — first LV mount pays for cold module loads.
      {:ok, _, _} = live(conn, "/remote")

      {micros, {:ok, _view, _html}} = :timer.tc(fn -> live(conn, "/remote") end)
      # 1s budget — the implementation target is ~50ms but QR-code
      # encoding via EQRCode has been clocked at 200-400ms on a
      # loaded suite. The real tripwire is "seconds" territory.
      assert micros < 1_000_000,
             "ConnectLive mount took #{div(micros, 1000)}ms — slow call slipped in"
    end
  end
end
