defmodule BoomLooperWeb.SystemSagasLiveTest do
  @moduledoc """
  Smoke tests for `/system/sagas`. Real saga recording is covered in
  `BoomLooper.Saga.RecorderTest`; this file just verifies the LV
  mounts, renders, and reflects recorded runs.
  """
  use BoomLooperWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BoomLooper.{Saga, Saga.Journal, Saga.Recorder}

  setup do
    :ets.delete_all_objects(Recorder.table())

    # Journal tests write to BOOMLOOPER_HOME/sagas.log. Ensure clean
    # state for the banner test and reset on exit.
    prev_home = System.get_env("BOOMLOOPER_HOME")

    tmp =
      Path.join(System.tmp_dir!(), "system_sagas_lv_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    System.put_env("BOOMLOOPER_HOME", tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)

      case prev_home do
        nil -> System.delete_env("BOOMLOOPER_HOME")
        val -> System.put_env("BOOMLOOPER_HOME", val)
      end
    end)

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

    test "shows the incomplete-saga red banner when the journal has in-flight entries",
         %{conn: conn} do
      # Simulate a crashed saga by writing :saga_started directly to
      # the journal (no matching :saga_completed or :saga_rolled_back).
      saga_id = :erlang.unique_integer([:positive, :monotonic])

      Journal.append(
        {:saga_started, saga_id, :incomplete_probe, %{ws_id: "abc"}, :manual, [:step_x], 0}
      )

      Journal.append({:step_started, saga_id, :step_x, %{}})

      {:ok, _view, html} = live(conn, "/system/sagas")

      assert html =~ "incomplete saga"
      assert html =~ "incomplete_probe"
      assert html =~ "crashed at step_x"
    end
  end
end
