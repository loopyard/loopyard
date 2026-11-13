defmodule Loopyard.Workstation.SignInDeviceTest do
  @moduledoc """
  The guided Codex sign-in — `Workstation.SignIn`'s `:device` flow: the CLI
  prints a verification URL and a one-time code, the human approves elsewhere,
  the CLI exits having written a credential FILE, which the wrapper prints
  between markers and the flow stores WITH the identity
  (`Workstation.CredentialFile`). The transcript below is a real capture of
  `codex login --device-auth` (codex-cli 0.154.0) under SignIn's PTY, control
  sequences included, with the live one-time code replaced.
  """
  # async: false — drives the ONE named SignIn process via an app-env seam.
  use ExUnit.Case, async: false

  alias Loopyard.Events.Workstation.SignInChanged
  alias Loopyard.Workstation
  alias Loopyard.Workstation.{CredentialFile, SignIn}

  @url "https://auth.openai.com/codex/device"
  @code "ABCD-12345"
  @auth ~s({"OPENAI_API_KEY":null,"tokens":{"id_token":"eyJid.secret-id","access_token":"eyJac.secret-access","refresh_token":"rt_secret-refresh","account_id":"acct-1"},"last_refresh":"2026-11-12T23:53:00Z"})

  # Verbatim from the capture (only the code is swapped).
  defp prompt_frame do
    "\r\nWelcome to Codex [v\e[90m0.154.0\e[0m]\r\n\e[90mOpenAI's command-line coding agent\e[0m\r\n\r\n" <>
      "Follow these steps to sign in with ChatGPT using device code authorization:\r\n\r\n" <>
      "1. Open this link in your browser and sign in to your account\r\n" <>
      "   \e[94m#{@url}\e[0m\r\n\r\n" <>
      "2. Enter this one-time code \e[90m(expires in 15 minutes)\e[0m\r\n" <>
      "   \e[94m#{@code}\e[0m\r\n\r\n" <>
      "\e[90mContinue only if you started this login in Codex. If a website or another person gave you this code, cancel.\e[0m\r\n\r\n"
  end

  # What the wrapper prints after `codex login` exits 0 (shape verified in the
  # base image: one base64 line between the markers, CRLF under the PTY).
  defp file_frame(body \\ @auth) do
    "Successfully logged in.\r\nLOOPYARD:CREDENTIAL:BEGIN\r\n" <>
      Base.encode64(body) <> "\r\nLOOPYARD:CREDENTIAL:END\r\n"
  end

  describe "reading the device transcript" do
    test "finds the verification URL and the one-time code once both are complete" do
      assert SignIn.find_device(SignIn.clean(prompt_frame())) == {@url, @code}
      # The URL alone (the code not printed yet) is not a prompt.
      [head | _] = String.split(prompt_frame(), "2. Enter")
      assert SignIn.find_device(SignIn.clean(head)) == nil
      # The version banner (`v0.154.0`) is never taken for a code.
      refute SignIn.find_device(SignIn.clean("Welcome to Codex [v\e[90m0.154.0\e[0m]\r\n"))
    end

    test "decodes the credential file only once the end marker is in" do
      assert SignIn.find_file(SignIn.clean(file_frame())) == @auth
      cut = String.slice(file_frame(), 0, 80)
      assert SignIn.find_file(SignIn.clean(cut)) == nil
    end
  end

  describe "the flow" do
    setup do
      test = self()
      id = "signin-dev-#{System.unique_integer([:positive])}"
      :ok = Workstation.create(id)

      Application.put_env(:loopyard, :sign_in_transport, %{
        open: fn container, command ->
          handle = make_ref()
          send(test, {:opened, handle, container, command})
          {:ok, handle}
        end,
        write: fn _handle, data ->
          send(test, {:wrote, data})
          :ok
        end,
        close: fn _handle, container ->
          send(test, {:closed, container})
          :ok
        end
      })

      Loopyard.Events.Workstation.subscribe(id)

      on_exit(fn ->
        SignIn.cancel(id, "codex")
        Application.delete_env(:loopyard, :sign_in_transport)
        File.rm_rf(Workstation.dir(id))
      end)

      %{id: id}
    end

    defp cli(handle, data), do: send(Process.whereis(SignIn), {handle, {:data, data}})

    defp begin!(id) do
      :ok = SignIn.begin(id, "codex")
      assert_receive {:opened, handle, container, command}
      {handle, container, command}
    end

    test "link + code → approved → the file is stored with the identity, never in an event",
         %{id: id} do
      assert SignIn.supported?("codex")
      {handle, container, command} = begin!(id)

      # The vendor CLI with its credential dir pinned; the file printed only
      # if it exits 0. No quote or `$` beyond the wrapper's own single quotes.
      assert command ==
               "sh -c 'export CODEX_HOME=/opt/loopyard-signin && mkdir -p /opt/loopyard-signin && " <>
                 "codex login --device-auth -c cli_auth_credentials_store=file && " <>
                 "echo LOOPYARD:CREDENTIAL:BEGIN && base64 -w0 /opt/loopyard-signin/auth.json && " <>
                 "echo && echo LOOPYARD:CREDENTIAL:END'"

      assert_receive %SignInChanged{phase: :starting, tool: "codex"}

      # No paste-back step in a device flow.
      {a, b} = String.split_at(prompt_frame(), 200)
      cli(handle, a)
      cli(handle, b)
      assert_receive %SignInChanged{phase: :awaiting_approval, url: @url, user_code: @code}

      assert SignIn.status(id, "codex") ==
               %{phase: :awaiting_approval, url: @url, error: nil, user_code: @code}

      assert {:error, :not_waiting} = SignIn.submit_code(id, "codex", "anything")
      refute_received {:wrote, _}

      cli(handle, file_frame())
      assert_receive %SignInChanged{phase: :done} = done, 2_000
      assert_receive {:closed, ^container}

      assert CredentialFile.stored?(id, :codex)

      assert File.read!(Path.join([Workstation.dir(id), "credentials", "codex", "auth.json"])) ==
               @auth

      assert Loopyard.Harness.Catalog.credentialed?(:codex, id)

      # No event and no process state ever held the credential.
      refute inspect(done) =~ "secret"
      refute inspect(:sys.get_status(SignIn)) =~ "secret"
      assert SignIn.status(id, "codex").phase == :idle
    end

    test "the CLI exiting without the file (declined / expired) fails with one action",
         %{id: id} do
      {handle, container, _} = begin!(id)
      cli(handle, prompt_frame())
      assert_receive %SignInChanged{phase: :awaiting_approval}

      cli(handle, "Error logging in with device code: device code expired\r\n")
      send(Process.whereis(SignIn), {handle, {:exit_status, 0}})

      assert_receive %SignInChanged{phase: :failed, error: error}
      assert error =~ "Codex didn't confirm the sign-in"
      assert error =~ "Start it again"
      assert_receive {:closed, ^container}
      refute CredentialFile.stored?(id, :codex)
    end

    test "a garbage payload is refused, not stored", %{id: id} do
      {handle, _container, _} = begin!(id)
      cli(handle, prompt_frame())
      assert_receive %SignInChanged{phase: :awaiting_approval}

      cli(handle, file_frame("not json"))
      assert_receive %SignInChanged{phase: :failed, error: error}, 2_000
      assert error =~ "couldn't be saved"
      refute CredentialFile.stored?(id, :codex)
    end

    test "waiting past the code's life times out", %{id: id} do
      {handle, container, _} = begin!(id)
      cli(handle, prompt_frame())
      assert_receive %SignInChanged{phase: :awaiting_approval}

      send(Process.whereis(SignIn), {:flow_timeout, {id, "codex"}, handle})
      assert_receive %SignInChanged{phase: :failed, error: error}
      assert error =~ "timed out waiting for approval"
      assert_receive {:closed, ^container}
    end

    test "cancel ends the flow and its container", %{id: id} do
      {handle, container, _} = begin!(id)
      cli(handle, prompt_frame())
      assert_receive %SignInChanged{phase: :awaiting_approval}

      SignIn.cancel(id, "codex")
      assert_receive {:closed, ^container}
      assert_receive %SignInChanged{phase: :idle}
      assert SignIn.status(id, "codex").phase == :idle

      # Late output from the cancelled CLI is ignored.
      cli(handle, file_frame())
      refute_receive %SignInChanged{phase: :done}, 100
      refute CredentialFile.stored?(id, :codex)
    end
  end
end
