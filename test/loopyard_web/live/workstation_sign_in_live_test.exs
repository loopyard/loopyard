defmodule LoopyardWeb.WorkstationSignInLiveTest do
  @moduledoc """
  The Claude page's guided sign-in, end to end through the LiveView: one step
  on screen at a time, the link is the vendor's URL, and the page never
  receives the token.
  """
  # async: false — the ONE SignIn process, and the page switches "current".
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Loopyard.Workstation
  alias Loopyard.Workstation.{Env, SignIn}

  @url "https://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=xyz"
  @token "sk-ant-oat01-" <> String.duplicate("Zz9_-", 20)

  setup do
    test = self()
    previous = Workstation.current()
    id = "signin-lv-#{System.unique_integer([:positive])}"
    :ok = Workstation.create(id)

    Application.put_env(:loopyard, :sign_in_transport, %{
      open: fn _container, _command ->
        handle = make_ref()
        send(test, {:opened, handle})
        {:ok, handle}
      end,
      write: fn _handle, data ->
        send(test, {:wrote, data})
        :ok
      end,
      close: fn _handle, _container -> :ok end
    })

    on_exit(fn ->
      SignIn.cancel(id, "claude")
      Application.delete_env(:loopyard, :sign_in_transport)
      Workstation.set_current(previous)
      File.rm_rf(Workstation.dir(id))
    end)

    %{id: id}
  end

  defp cli(handle, data), do: send(Process.whereis(SignIn), {handle, {:data, data}})

  test "sign in: button → link + code box → signed in", %{conn: conn, id: id} do
    {:ok, view, html} = live(conn, "/workstations/#{id}/claude")
    assert html =~ "Sign in with Claude"
    assert has_element?(view, "button[phx-click=sign_in_start]", "Sign in to Claude")
    refute has_element?(view, "form[phx-submit=sign_in_code]")

    view |> element("button[phx-click=sign_in_start]") |> render_click()
    assert_receive {:opened, handle}
    assert render(view) =~ "Starting the sign-in"

    cli(handle, "Use the url below\r\n" <> @url <> "\r\nPaste code here >")
    _ = :sys.get_state(SignIn)

    # The link is the vendor's own page, opened in a new tab.
    assert has_element?(view, ~s|a[href="#{@url}"][target=_blank][rel~=noopener]|)
    assert render(view) =~ "Switch accounts there before you approve"

    view
    |> form("form[phx-submit=sign_in_code]", %{"code" => "the-code#state"})
    |> render_submit()

    assert_receive {:wrote, "the-code#state\r"}
    assert render(view) =~ "Checking the code"

    cli(handle, "Your token:\r\n" <> @token <> "\r\n")

    assert Enum.any?(1..40, fn _ ->
             Process.sleep(25)
             render(view) =~ "Signed in."
           end)

    html = render(view)
    refute html =~ "sk-ant"
    assert Env.all(id)["CLAUDE_CODE_OAUTH_TOKEN"] == @token
  end

  test "a reload mid-flow lands on the same step", %{conn: conn, id: id} do
    :ok = SignIn.begin(id, "claude")
    assert_receive {:opened, handle}
    cli(handle, @url <> "\r\n")
    _ = :sys.get_state(SignIn)

    {:ok, view, _html} = live(conn, "/workstations/#{id}/claude")
    assert has_element?(view, ~s|a[href="#{@url}"]|)

    view |> element("button[phx-click=sign_in_cancel]") |> render_click()
    assert has_element?(view, "button[phx-click=sign_in_start]")
  end

  test "an integration without a guided sign-in shows none", %{conn: conn, id: id} do
    {:ok, _view, html} = live(conn, "/workstations/#{id}/fly")
    refute html =~ "Sign in with"
  end
end
