defmodule Loopyard.Source.Local.MutagenTest do
  use ExUnit.Case, async: false

  alias Loopyard.Source.Local.Mutagen

  # Stub the CLI runner so these tests never actually shell out to mutagen.
  # Each test sets a function via Application env; the Mutagen module reads
  # it on every call. We reset it after each test.
  setup do
    on_exit(fn -> Application.delete_env(:loopyard, :mutagen_runner) end)
    :ok
  end

  defp stub_runner(fun) do
    Application.put_env(:loopyard, :mutagen_runner, fun)
  end

  describe "session_name/1" do
    test "builds loopyard-<workspace_id>" do
      assert Mutagen.session_name("abcd") == "loopyard-abcd"
    end
  end

  describe "start_sync/3" do
    test "passes --name, --sync-mode, ignore flags, worktree path, and docker endpoint" do
      stub_runner(fn args ->
        send(self(), {:args, args})
        {"", 0}
      end)

      assert :ok = Mutagen.start_sync("deadbeef", "/tmp/worktree", "loopyard-deadbeef-workspace-1")
      assert_received {:args, args}

      assert "sync" in args
      assert "create" in args
      assert "--name=loopyard-deadbeef" in args
      assert "--sync-mode=two-way-safe" in args
      assert "--ignore=.git" in args
      assert "--ignore=.loopyard" in args
      assert "/tmp/worktree" in args
      assert "docker://loopyard-deadbeef-workspace-1/workspace" in args
    end

    test "treats 'already exists' output as :ok (idempotent)" do
      stub_runner(fn _args -> {"session with name loopyard-x already exists", 1} end)
      assert :ok = Mutagen.start_sync("x", "/tmp/wt", "loopyard-x-workspace-1")
    end

    test "returns {:error, reason} on other failures" do
      stub_runner(fn _args -> {"daemon not running", 1} end)

      assert {:error, "daemon not running"} =
               Mutagen.start_sync("x", "/tmp/wt", "loopyard-x-workspace-1")
    end
  end

  describe "terminate_sync/1" do
    test "returns :ok when session exists" do
      stub_runner(fn _args -> {"terminated", 0} end)
      assert :ok = Mutagen.terminate_sync("abcd")
    end

    test "returns :ok when session does not exist (idempotent)" do
      stub_runner(fn _args -> {"session does not exist", 1} end)
      assert :ok = Mutagen.terminate_sync("abcd")
    end
  end

  describe "session_status/1" do
    test "parses :running from watching-for-changes output" do
      stub_runner(fn _args -> {"Name: loopyard-x\nStatus: Watching for changes\n", 0} end)
      assert :running = Mutagen.session_status("x")
    end

    test "parses :paused" do
      stub_runner(fn _args -> {"Name: loopyard-x\nStatus: Paused\n", 0} end)
      assert :paused = Mutagen.session_status("x")
    end

    test "parses :errored from a problem status" do
      stub_runner(fn _args -> {"Name: loopyard-x\nStatus: Problem synchronizing\n", 0} end)
      assert :errored = Mutagen.session_status("x")
    end

    test ":missing when mutagen reports no such session" do
      stub_runner(fn _args -> {"session loopyard-x does not exist", 1} end)
      assert :missing = Mutagen.session_status("x")
    end

    test ":unknown when mutagen call fails for unrelated reasons" do
      stub_runner(fn _args -> {"daemon unreachable", 1} end)
      assert :unknown = Mutagen.session_status("x")
    end
  end

  describe "parse_details/1" do
    @full_output """
    Name: loopyard-abc123
    Identifier: sync_abc123
    Alpha:
      URL: /Users/me/.loopyard/worktrees/abc123
      Connected: Yes
      Watching: polling (5s interval)
      Scanned files: 142 files (3.2 MB)
    Beta:
      URL: docker://loopyard-abc123-workspace-1/workspace
      Connected: Yes
      Watching: polling (5s interval)
      Scanned files: 142 files (3.2 MB)
    Status: Watching for changes
    """

    test "parses connected endpoints and file counts from full output" do
      details = Mutagen.parse_details(@full_output)

      assert details.status_text == "Watching for changes"
      assert details.alpha_connected == true
      assert details.beta_connected == true
      assert details.alpha_files == %{files: 142, size: "3.2 MB"}
      assert details.beta_files == %{files: 142, size: "3.2 MB"}
      assert details.conflicts == 0
      assert details.scan_problems == 0
    end

    test "returns nil for minimal output without Alpha/Beta blocks" do
      assert Mutagen.parse_details("Name: loopyard-x\nStatus: Watching for changes\n") == nil
    end

    test "parses disconnected beta" do
      out = """
      Name: loopyard-abc
      Alpha:
        URL: /tmp/wt
        Connected: Yes
      Beta:
        URL: docker://loopyard-abc-ws-1/workspace
        Connected: No
      Status: Waiting for beta
      """

      details = Mutagen.parse_details(out)
      assert details.alpha_connected == true
      assert details.beta_connected == false
      assert details.status_text == "Waiting for beta"
    end

    test "parses conflicts and scan problems" do
      out = """
      Name: loopyard-abc
      Alpha:
        URL: /tmp/wt
        Connected: Yes
      Beta:
        URL: docker://loopyard-abc-ws-1/workspace
        Connected: Yes
      Status: Problem synchronizing
      Conflicts: 3
      Scan problems: 1
      """

      details = Mutagen.parse_details(out)
      assert details.conflicts == 3
      assert details.scan_problems == 1
    end

    test "session_status returns {:rich, status, details} for full output" do
      stub_runner(fn _args ->
        {@full_output, 0}
      end)

      assert {:rich, :running, details} = Mutagen.session_status("abc123")
      assert details.status_text == "Watching for changes"
      assert details.alpha_connected == true
    end
  end
end
