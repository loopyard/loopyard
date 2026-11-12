defmodule Loopyard.Workstation.SignInTest do
  @moduledoc """
  The guided "Sign in to Claude" flow: read the vendor CLI's transcript, walk
  the phases, store the token, and never leak the token or the pasted code
  into an event. The CLI is replaced by the `:sign_in_transport` seam — the
  transcripts below are trimmed from a real `claude setup-token` capture
  (Claude Code 2.1.268), control sequences included.
  """
  # async: false — drives the ONE named SignIn process via an app-env seam.
  use ExUnit.Case, async: false

  alias Loopyard.Events.Workstation.SignInChanged
  alias Loopyard.Workstation
  alias Loopyard.Workstation.{Env, SignIn}

  @url "https://claude.com/cai/oauth/authorize?code=true&client_id=abc&response_type=code&scope=user%3Ainference&state=xyz"
  @token "sk-ant-oat01-" <> String.duplicate("Ab3_-", 20)

  # A TUI frame: cursor moves instead of spaces, colour codes around words.
  defp url_frame do
    "\e[?25l\e[1mWelcome\e[1Cto\e[1CClaude\e[1CCode\e[22m\r\n" <>
      "Browser\e[1Cdidn't\e[1Copen?\e[1CUse\e[1Cthe\e[1Curl\e[1Cbelow\r\n" <>
      "\e[38;5;153m" <>
      @url <> "\e[39m\r\n" <> "Paste\e[1Ccode\e[1Chere\e[1Cif\e[1Cprompted\e[1C>\e[1C"
  end

  defp token_frame do
    "\e[2K\e[32m✓\e[39m\e[1CLong-lived\e[1Ctoken\e[1Ccreated\r\n" <>
      "Your\e[1COAuth\e[1Ctoken:\r\n\e[33m" <>
      @token <> "\e[39m\r\n\r\nStore\e[1Cit\e[1Csecurely.\r\n"
  end

  describe "reading the transcript" do
    test "finds the authorize URL once it is complete" do
      assert SignIn.find_url(SignIn.clean(url_frame())) == @url
      # A chunk boundary mid-URL: nothing yet, rather than a truncated link.
      assert SignIn.find_url(SignIn.clean("...\r\n" <> String.slice(@url, 0, 40))) == nil
    end

    test "finds the token only when it is complete" do
      assert SignIn.find_token(SignIn.clean(token_frame()), "sk-ant-oat01-") == @token
      cut = "token:\r\n" <> String.slice(@token, 0, 50)
      assert SignIn.find_token(SignIn.clean(cut), "sk-ant-oat01-") == nil
    end

    test "recognizes a refused code through the TUI's missing spaces" do
      assert SignIn.rejected?(
               SignIn.clean("OAuth\e[1Cerror:\e[1CRequest\e[1Cfailed\r\nPress\e[1CEnter")
             )

      refute SignIn.rejected?(SignIn.clean(url_frame()))
    end
  end

  describe "the flow" do
    setup do
      test = self()
      id = "signin-#{System.unique_integer([:positive])}"
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
        SignIn.cancel(id, "claude")
        Application.delete_env(:loopyard, :sign_in_transport)
        File.rm_rf(Workstation.dir(id))
      end)

      %{id: id}
    end

    defp cli(handle, data), do: send(Process.whereis(SignIn), {handle, {:data, data}})

    test "URL → code → token lands on the workstation; events never carry a secret", %{id: id} do
      assert SignIn.status(id, "claude").phase == :idle
      assert :ok = SignIn.begin(id, "claude")
      assert_receive {:opened, handle, container, "claude setup-token"}
      assert container =~ "signin-#{id}-"
      assert_receive %SignInChanged{phase: :starting, tool: "claude", url: nil}

      # A code before the CLI is ready is refused, not typed into the void.
      assert {:error, :not_waiting} = SignIn.submit_code(id, "claude", "abc#def")

      # The URL arrives split across two chunks.
      {a, b} = String.split_at(url_frame(), 120)
      cli(handle, a)
      cli(handle, b)
      assert_receive %SignInChanged{phase: :awaiting_code, url: @url}
      assert SignIn.status(id, "claude") == %{phase: :awaiting_code, url: @url, error: nil}

      assert {:error, :invalid_code} = SignIn.submit_code(id, "claude", "two words")
      assert {:error, :invalid_code} = SignIn.submit_code(id, "claude", "   ")
      assert :ok = SignIn.submit_code(id, "claude", "  the-code#the-state \n")
      # Trimmed, and Enter is a carriage return for the raw-mode prompt.
      assert_receive {:wrote, "the-code#the-state\r"}
      assert_receive %SignInChanged{phase: :exchanging} = exchanging
      refute inspect(exchanging) =~ "the-code"

      cli(handle, token_frame())
      assert_receive %SignInChanged{phase: :done} = done, 2_000
      refute inspect(done) =~ "sk-ant"
      assert_receive {:closed, ^container}

      assert Env.all(id)["CLAUDE_CODE_OAUTH_TOKEN"] == @token
      assert SignIn.status(id, "claude").phase == :idle
      # The transcript never sits in process state where a crash report or
      # :sys.get_status could print it.
      refute inspect(:sys.get_status(SignIn)) =~ "sk-ant"
    end

    test "a refused code fails with one action, and tears the container down", %{id: id} do
      :ok = SignIn.begin(id, "claude")
      assert_receive {:opened, handle, container, _}
      cli(handle, url_frame())
      assert_receive %SignInChanged{phase: :awaiting_code}
      :ok = SignIn.submit_code(id, "claude", "wrong")

      cli(
        handle,
        "OAuth\e[1Cerror:\e[1CRequest\e[1Cfailed\e[1Cwith\e[1Cstatus\e[1Ccode\e[1C400\r\n"
      )

      assert_receive %SignInChanged{phase: :failed, error: error}
      assert error =~ "didn't accept that code"
      assert_receive {:closed, ^container}
      assert Env.all(id)["CLAUDE_CODE_OAUTH_TOKEN"] == nil
      assert SignIn.status(id, "claude").phase == :idle
    end

    test "the CLI dying mid-flow is a failure, not a hang", %{id: id} do
      :ok = SignIn.begin(id, "claude")
      assert_receive {:opened, handle, _container, _}
      send(Process.whereis(SignIn), {handle, {:exit_status, 125}})
      assert_receive %SignInChanged{phase: :failed, error: error}
      assert error =~ "Start it again"
    end

    test "beginning again replaces the running flow; cancel ends it", %{id: id} do
      :ok = SignIn.begin(id, "claude")
      assert_receive {:opened, first, first_container, _}
      :ok = SignIn.begin(id, "claude")
      assert_receive {:closed, ^first_container}
      assert_receive {:opened, second, second_container, _}
      refute first == second

      # Output from the replaced CLI is ignored.
      cli(first, url_frame())
      refute_receive %SignInChanged{phase: :awaiting_code}, 100

      SignIn.cancel(id, "claude")
      assert_receive {:closed, ^second_container}
      assert_receive %SignInChanged{phase: :idle}
    end

    test "an integration without a guided sign-in, or an unknown workstation, is refused" do
      refute SignIn.supported?("fly")
      assert SignIn.supported?("claude")
      assert {:error, :unsupported} = SignIn.begin("anyone", "fly")
      assert {:error, :not_found} = SignIn.begin("no-such-workstation-xyz", "claude")
    end
  end
end
