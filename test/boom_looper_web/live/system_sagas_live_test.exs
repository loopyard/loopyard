defmodule BoomLooperWeb.SystemSagasLiveTest do
  @moduledoc """
  Smoke tests for `/system/sagas`. Real saga recording is covered in
  `BoomLooper.Saga.RecorderTest`; this file just verifies the LV
  mounts, renders, and reflects recorded runs.
  """
  use BoomLooperWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BoomLooper.{Saga, Saga.Recorder}

  setup do
    :ets.delete_all_objects(Recorder.table())
    :ok
  end

  describe "mount" do
    test "renders the sagas page with breadcrumb + empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, "/system/sagas")

      assert html =~ "Sagas"
      assert has_element?(view, "a[href='/system']")
      assert html =~ "No sagas recorded yet"
    end

    test "displays a recorded saga run", %{conn: conn} do
      Saga.run(
        [%{name: :probe, run: fn _ -> {:ok, %{}} end}],
        name: :lv_render_test
      )

      {:ok, _view, html} = live(conn, "/system/sagas")

      assert html =~ "lv_render_test"
      assert html =~ "succeeded"
      assert html =~ "probe"
    end

    test "shows rollback_failed banner styling when a rollback errors", %{conn: conn} do
      Saga.run(
        [
          %{
            name: :a,
            run: fn _ -> {:ok, %{}} end,
            rollback: fn _ -> {:error, :cant_undo} end
          },
          %{name: :b, run: fn _ -> {:error, :nope} end}
        ],
        name: :lv_rollback_failed_test
      )

      {:ok, _view, html} = live(conn, "/system/sagas")

      assert html =~ "lv_rollback_failed_test"
      assert html =~ "rollback failed"
    end
  end
end
