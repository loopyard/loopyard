defmodule LoopyardWeb.NotificationsAlertTest do
  @moduledoc """
  A SYSTEM alert (the Docker disk filling up, #117) is one slide on the deck:
  the cause, the one action, Free up space / Dismiss — no composer, since there
  is no agent to talk to — and it counts in the Notifications badge.
  """
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Loopyard.Docker.Disk
  alias Loopyard.Notifications
  alias Loopyard.Notifications.{Item, Priority}

  setup do
    :ets.delete(:notifications, Disk.alert_id())
    on_exit(fn -> :ets.delete(:notifications, Disk.alert_id()) end)
    :ok
  end

  defp raise_alert(level, reason) do
    Notifications.upsert(Disk.alert_item(level, {level, reason}))
    Notifications.sync()
  end

  test "upsert raises once, then updates the open item in place" do
    raise_alert(:degraded, "2.0 GB free of 96 GB")
    %Item{raised_at: raised} = Notifications.get(Disk.alert_id())

    raise_alert(:down, "100 MB free of 96 GB")

    assert %Item{status: :open, label: label, raised_at: ^raised} =
             Notifications.get(Disk.alert_id())

    assert label =~ "100 MB free"
    assert Enum.count(Notifications.open(), &(&1.id == Disk.alert_id())) == 1
  end

  test "an alert leads the inbox and counts as waiting on a human" do
    item = Disk.alert_item(:down, {:down, "x"})
    assert Priority.tier(item) <= Priority.tier(%Item{kind: :question})
    assert :alert in Item.needs_human_kinds()
    refute :alert in Item.decision_kinds(), "the decision reconcile sweep must never touch it"
  end

  test "the deck shows the alert with its action, Free up space and Dismiss, and no composer",
       %{conn: conn} do
    raise_alert(:down, "165 MB free of 96 GB")

    {:ok, view, html} = live(conn, "/notifications/loopyard/docker-disk")
    assert html =~ "Agents can&#39;t run" or html =~ "Agents can't run"
    assert html =~ "165 MB free of 96 GB"
    assert html =~ "removes its own leftovers automatically"
    assert has_element?(view, ~s(a[href="/system/docker"]), "Free up space")
    assert has_element?(view, "button[phx-click=dismiss_item][phx-value-id='docker-disk']")
    refute has_element?(view, "#chat-form-loopyard-docker-disk-all")

    render_click(view, "dismiss_item", %{"id" => Disk.alert_id()})
    Notifications.sync()
    assert %{status: :dismissed} = Notifications.get(Disk.alert_id())
    assert render(view) =~ "it comes back if it gets worse"
  end

  test "a recovered alert reads as a receipt", %{conn: conn} do
    raise_alert(:degraded, "2.0 GB free of 96 GB")
    {:ok, view, _html} = live(conn, "/notifications")

    Notifications.settle(Disk.alert_id(), :recovered)
    Notifications.sync()
    send(view.pid, :tick)
    assert render(view) =~ "Recovered"
  end
end
