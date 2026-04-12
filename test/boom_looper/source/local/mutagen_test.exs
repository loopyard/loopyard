defmodule BoomLooper.Source.Local.MutagenTest do
  use ExUnit.Case, async: false

  alias BoomLooper.Source.Local.Mutagen

  # Stub the CLI runner so these tests never actually shell out to mutagen.
  # Each test sets a function via Application env; the Mutagen module reads
  # it on every call. We reset it after each test.
  setup do
    on_exit(fn -> Application.delete_env(:boom_looper, :mutagen_runner) end)
    :ok
  end

  defp stub_runner(fun) do
    Application.put_env(:boom_looper, :mutagen_runner, fun)
  end

  describe "session_name/1" do
    test "builds bl-<workspace_id>" do
      assert Mutagen.session_name("abcd") == "bl-abcd"
    end
  end

  describe "start_sync/3" do
    test "passes --name, --sync-mode, ignore flags, worktree path, and docker endpoint" do
      stub_runner(fn args ->
        send(self(), {:args, args})
        {"", 0}
      end)

      assert :ok = Mutagen.start_sync("deadbeef", "/tmp/worktree", "bl-deadbeef-workspace-1")
      assert_received {:args, args}

      assert "sync" in args
      assert "create" in args
      assert "--name=bl-deadbeef" in args
      assert "--sync-mode=two-way-safe" in args
      assert "--ignore=.git" in args
      assert "--ignore=.boomlooper" in args
      assert "/tmp/worktree" in args
      assert "docker://bl-deadbeef-workspace-1/workspace" in args
    end

    test "treats 'already exists' output as :ok (idempotent)" do
      stub_runner(fn _args -> {"session with name bl-x already exists", 1} end)
      assert :ok = Mutagen.start_sync("x", "/tmp/wt", "bl-x-workspace-1")
    end

    test "returns {:error, reason} on other failures" do
      stub_runner(fn _args -> {"daemon not running", 1} end)
      assert {:error, "daemon not running"} = Mutagen.start_sync("x", "/tmp/wt", "bl-x-workspace-1")
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
      stub_runner(fn _args -> {"Name: bl-x\nStatus: Watching for changes\n", 0} end)
      assert :running = Mutagen.session_status("x")
    end

    test "parses :paused" do
      stub_runner(fn _args -> {"Name: bl-x\nStatus: Paused\n", 0} end)
      assert :paused = Mutagen.session_status("x")
    end

    test "parses :errored from a problem status" do
      stub_runner(fn _args -> {"Name: bl-x\nStatus: Problem synchronizing\n", 0} end)
      assert :errored = Mutagen.session_status("x")
    end

    test ":missing when mutagen reports no such session" do
      stub_runner(fn _args -> {"session bl-x does not exist", 1} end)
      assert :missing = Mutagen.session_status("x")
    end

    test ":unknown when mutagen call fails for unrelated reasons" do
      stub_runner(fn _args -> {"daemon unreachable", 1} end)
      assert :unknown = Mutagen.session_status("x")
    end
  end
end
