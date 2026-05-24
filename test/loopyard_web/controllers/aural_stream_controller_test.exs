defmodule AuralWeb.StreamControllerTest do
  use LoopyardWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  describe "POST /aural/diag" do
    test "logs the JSON payload and returns 204", %{conn: conn} do
      log =
        capture_log(fn ->
          conn =
            conn
            |> put_req_header("content-type", "application/json")
            |> post("/aural/diag", %{label: "audio:error", code: 4, message: "test"})

          assert response(conn, 204)
        end)

      assert log =~ "[aural:diag]"
      assert log =~ "audio:error"
      assert log =~ ~s|"code" => 4|
    end

    test "accepts empty payload", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/aural/diag", %{})

      assert response(conn, 204)
    end

    test "no CSRF token required (endpoint is outside the :browser pipeline)", %{conn: conn} do
      # Diag is reached from a browser fetch() with no CSRF token —
      # explicitly tested because the original implementation lived
      # in the :browser pipeline and rejected every diag POST silently.
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/aural/diag", %{label: "test"})

      assert response(conn, 204)
    end
  end

  describe "route resolution" do
    test "GET /aural/:channel_id/stream.mp3 routes to AuralWeb.StreamController.stream/2" do
      route =
        Phoenix.Router.route_info(LoopyardWeb.Router, "GET", "/aural/abc123/stream.mp3", "")

      assert route.plug == AuralWeb.StreamController
      assert route.plug_opts == :stream
      assert route.path_params == %{"channel_id" => "abc123"}
    end

    test "POST /aural/diag routes to AuralWeb.StreamController.diag/2" do
      route = Phoenix.Router.route_info(LoopyardWeb.Router, "POST", "/aural/diag", "")
      assert route.plug == AuralWeb.StreamController
      assert route.plug_opts == :diag
    end

    test "GET /aural routes to the redirect controller" do
      route = Phoenix.Router.route_info(LoopyardWeb.Router, "GET", "/aural", "")
      assert route.plug == AuralWeb.RedirectController
      assert route.plug_opts == :new_channel
    end
  end
end
