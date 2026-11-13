defmodule LoopyardWeb.WorkstationDeviceSignInLiveTest do
  @moduledoc """
  The Codex page's guided sign-in (a device flow) through the LiveView: the
  same section as Claude's, but step 2 is a code to ENTER on the vendor's page
  (no paste box), then a waiting state the page leaves by itself.
  """
  # async: false — the ONE SignIn process, and the page switches "current".
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Loopyard.Workstation
  alias Loopyard.Workstation.{CredentialFile, SignIn}

  @url "https://auth.openai.com/codex/device"
  @code "WXYZ-98765"
  @auth ~s({"tokens":{"refresh_token":"rt_never_rendered"}})

  setup do
    test = self()
    previous = Workstation.current()
    id = "signin-dlv-#{System.unique_integer([:positive])}"
    :ok = Workstation.create(id)

    Application.put_env(:loopyard, :sign_in_transport, %{
      open: fn _container, _command ->
        handle = make_ref()
        send(test, {:opened, handle})
        {:ok, handle}
      end,
      write: fn _handle, _data -> :ok end,
      close: fn _handle, _container -> :ok end
    })

    on_exit(fn ->
      SignIn.cancel(id, "codex")
      Application.delete_env(:loopyard, :sign_in_transport)
      Workstation.set_current(previous)
      File.rm_rf(Workstation.dir(id))
    end)

    %{id: id}
  end

  defp cli(handle, data) do
    send(Process.whereis(SignIn), {handle, {:data, data}})
    _ = :sys.get_state(SignIn)
  end

  defp prompt,
    do:
      "1. Open this link in your browser\r\n   \e[94m#{@url}\e[0m\r\n" <>
        "2. Enter this one-time code\r\n   \e[94m#{@code}\e[0m\r\n"

  test "sign in: button → link + code to enter → waiting → signed in", %{conn: conn, id: id} do
    {:ok, view, html} = live(conn, "/workstations/#{id}/codex")
    assert html =~ "Sign in with Codex"
    assert html =~ "enter the code shown here"
    assert has_element?(view, "button[phx-click=sign_in_start]", "Sign in to Codex")

    view |> element("button[phx-click=sign_in_start]") |> render_click()
    assert_receive {:opened, handle}
    assert render(view) =~ "Starting the sign-in"

    cli(handle, prompt())

    assert has_element?(view, ~s|a[href="#{@url}"][target=_blank][rel~=noopener]|)
    # The code is shown (and copyable) — and there is nothing to paste back.
    assert has_element?(view, ~s|#sign-in-user-code[data-copy="#{@code}"]|)
    refute has_element?(view, "form[phx-submit=sign_in_code]")
    assert render(view) =~ "Waiting for you to approve"
    assert has_element?(view, "button[phx-click=sign_in_cancel]")

    cli(
      handle,
      "LOOPYARD:CREDENTIAL:BEGIN\r\n#{Base.encode64(@auth)}\r\nLOOPYARD:CREDENTIAL:END\r\n"
    )

    assert Enum.any?(1..40, fn _ ->
             Process.sleep(25)
             render(view) =~ "Signed in."
           end)

    refute render(view) =~ "rt_never_rendered"
    assert CredentialFile.stored?(id, :codex)
  end

  test "a reload mid-flow lands on the same step, code included", %{conn: conn, id: id} do
    :ok = SignIn.begin(id, "codex")
    assert_receive {:opened, handle}
    cli(handle, prompt())

    {:ok, view, _html} = live(conn, "/workstations/#{id}/codex")
    assert has_element?(view, ~s|a[href="#{@url}"]|)
    assert render(view) =~ @code

    view |> element("button[phx-click=sign_in_cancel]") |> render_click()
    assert has_element?(view, "button[phx-click=sign_in_start]")
  end
end
