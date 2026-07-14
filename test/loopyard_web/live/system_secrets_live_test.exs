defmodule LoopyardWeb.SystemSecretsLiveTest do
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Loopyard.Secrets

  # Unique key per run so we never collide with real stored secrets, and we
  # delete it in on_exit so the shared ~/.loopyard/secrets.json stays clean.
  setup do
    key = "TEST_SECRET_#{System.unique_integer([:positive])}"
    on_exit(fn -> Secrets.delete(key) end)
    %{key: key}
  end

  test "add, reveal, rotate, and delete a secret through the UI", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, "/system/secrets")

    # Add
    view
    |> form("form[phx-submit=save]",
      secret: %{key: key, name: "My Token", value: "sekret-1", scope: ""}
    )
    |> render_submit()

    assert Secrets.get(key) == {:ok, "sekret-1"}
    html = render(view)
    assert html =~ key
    assert html =~ "My Token"
    assert html =~ "global"

    # Reveal shows the value
    html = view |> element("button[phx-click=reveal][phx-value-key=#{key}]") |> render_click()
    assert html =~ "sekret-1"

    # Rotate (same key, new value) overwrites
    view
    |> form("form[phx-submit=save]",
      secret: %{key: key, name: "My Token", value: "sekret-2", scope: ""}
    )
    |> render_submit()

    assert Secrets.get(key) == {:ok, "sekret-2"}

    # Delete removes it
    view |> element("button[phx-click=delete][phx-value-key=#{key}]") |> render_click()
    assert Secrets.get(key) == :not_found
  end

  test "scoped secret records its scope list", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, "/system/secrets")

    view
    |> form("form[phx-submit=save]",
      secret: %{key: key, name: "", value: "v", scope: "ws-1, proj-2"}
    )
    |> render_submit()

    assert %{scope: ["ws-1", "proj-2"]} = Enum.find(Secrets.list(), &(&1.key == key))
    # Name defaults to the key when blank
    assert %{name: ^key} = Enum.find(Secrets.list(), &(&1.key == key))
  end

  test "rejects a blank key", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/system/secrets")

    html =
      view
      |> form("form[phx-submit=save]", secret: %{key: "", name: "", value: "v", scope: ""})
      |> render_submit()

    assert html =~ "key is required"
  end
end
