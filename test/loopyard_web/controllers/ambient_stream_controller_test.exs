defmodule LoopyardWeb.AmbientStreamControllerTest do
  use LoopyardWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  describe "POST /ambient/diag" do
    test "logs the JSON payload and returns 204", %{conn: conn} do
      log =
        capture_log(fn ->
          conn =
            conn
            |> put_req_header("content-type", "application/json")
            |> post("/ambient/diag", %{label: "audio:error", code: 4, message: "test"})

          assert response(conn, 204)
        end)

      assert log =~ "[ambient:diag]"
      assert log =~ "audio:error"
      assert log =~ ~s|"code" => 4|
    end

    test "accepts empty payload", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/ambient/diag", %{})

      assert response(conn, 204)
    end

    test "no CSRF token required (endpoint is outside the :browser pipeline)", %{conn: conn} do
      # Diag is reached from a browser fetch() with no CSRF token —
      # explicitly tested because the original implementation lived
      # in the :browser pipeline and rejected every diag POST silently.
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/ambient/diag", %{label: "test"})

      assert response(conn, 204)
    end
  end

  describe "route resolution" do
    test "GET /ambient/stream.opus routes to AmbientStreamController.stream/2" do
      route = Phoenix.Router.route_info(LoopyardWeb.Router, "GET", "/ambient/stream.opus", "")
      assert route.plug == LoopyardWeb.AmbientStreamController
      assert route.plug_opts == :stream
    end

    test "POST /ambient/diag routes to AmbientStreamController.diag/2" do
      route = Phoenix.Router.route_info(LoopyardWeb.Router, "POST", "/ambient/diag", "")
      assert route.plug == LoopyardWeb.AmbientStreamController
      assert route.plug_opts == :diag
    end
  end
end
