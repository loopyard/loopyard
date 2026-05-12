defmodule Loopyard.EvalRunnerTest do
  use ExUnit.Case, async: false

  alias Loopyard.EvalRunner

  setup do
    Loopyard.StateKeeper.ensure_tables!()

    # Wipe ETS directly — faster than remove_project which does synchronous
    # Docker cleanup and can timeout.
    :ets.delete_all_objects(:project_registry)
    :ets.delete_all_objects(:workspace_registry)

    # Clean up eval run output (not the eval configs)
    for dir <- Path.wildcard("evals/*/runs") do
      File.rm_rf!(dir)
    end

    # Clean up test-specific eval dirs created by record_run tests
    File.rm_rf("evals/test-project")
    File.rm_rf("evals/my_cool_project")
    File.rm_rf("evals/errored")

    on_exit(fn ->
      for dir <- Path.wildcard("evals/*/runs") do
        File.rm_rf!(dir)
      end

      File.rm_rf("evals/test-project")
      File.rm_rf("evals/my_cool_project")
      File.rm_rf("evals/errored")
    end)

    :ok
  end

  defp base_result(overrides \\ %{}) do
    Map.merge(
      %{
        outcome: :completed,
        source: "/tmp/test-project",
        project_name: "test-project",
        agent_id: "abc123",
        duration_ms: 5000,
        timestamp: DateTime.utc_now(),
        status: :idle,
        message_count: 10,
        tool_calls: 5,
        errors: 0,
        error_messages: [],
        services: %{},
        nudges: 0,
        tool_usage: %{}
      },
      overrides
    )
  end

  describe "list_evals/0" do
    test "returns evals from priv/evals.json" do
      evals = EvalRunner.list_evals()
      assert is_list(evals)
      names = Enum.map(evals, & &1.name)
      assert "maybe-finance" in names
      assert "discourse" in names
      assert "chatwoot" in names
    end

    test "each eval has a git_url" do
      for eval <- EvalRunner.list_evals() do
        assert is_binary(eval.git_url)
        assert String.starts_with?(eval.git_url, "https://")
      end
    end
  end

  describe "eval/2" do
    test "returns error for unknown eval name" do
      assert {:error, msg} = EvalRunner.eval("nonexistent")
      assert msg =~ "Unknown eval"
      assert msg =~ "maybe-finance"
    end
  end

  describe "check_services/1" do
    test "returns empty map when no services running" do
      assert EvalRunner.check_services("/nonexistent/path") == %{}
    end
  end

  describe "record_run/2" do
    test "writes eval result to file" do
      result =
        base_result(%{
          services: %{"workspace" => "running", "postgres" => "running"},
          tool_usage: %{"Read" => 5, "service_status" => 2}
        })

      path = EvalRunner.record_run("test-project", result)

      assert File.exists?(path)
      content = File.read!(path)
      assert content =~ "# Eval: test-project"
      assert content =~ "completed"
      assert content =~ "workspace: running"
      assert content =~ "postgres: running"
      assert content =~ "Read: 5"
    end

    test "sanitizes project name for directory" do
      result =
        base_result(%{
          outcome: :failed,
          project_path: "/tmp/My Cool Project!",
          project_name: "My Cool Project!",
          agent_id: "def456",
          status: :crashed
        })

      path = EvalRunner.record_run("My Cool Project!", result)

      assert path =~ "evals/my_cool_project/runs/"
      assert File.exists?(path)
    end

    test "records error messages and nudges" do
      result =
        base_result(%{
          outcome: :stalled,
          project_path: "/tmp/errored",
          project_name: "errored",
          agent_id: "err789",
          errors: 2,
          error_messages: ["CLI crashed", "Session lost"],
          nudges: 3
        })

      path = EvalRunner.record_run("errored", result)
      content = File.read!(path)

      assert content =~ "CLI crashed"
      assert content =~ "Session lost"
      assert content =~ "Errors:** 2"
      assert content =~ "Nudges:** 3"
    end
  end

  describe "count_session_crashes/1" do
    # Used by poll_agent to detect a *new* SDK crash since the last
    # retry, even when tool/assistant messages appear after the error
    # (which is common because ChatAgent auto-restarts sessions).
    # The old `List.last(messages)` check missed those cases and
    # burned a real nudge on what was actually a crash recovery.

    test "counts zero when no crash error is present" do
      state = %{
        messages: [
          %{role: :user, content: "hi"},
          %{role: :assistant, content: "hello"}
        ]
      }

      assert EvalRunner.count_session_crashes(state) == 0
    end

    test "counts the 'Agent stopped responding' errors" do
      state = %{
        messages: [
          %{role: :user, content: "setup"},
          %{role: :error, content: "Agent stopped responding. Send a message to retry."},
          %{role: :assistant, content: "recovered"},
          %{role: :tool, content: "ran something"},
          %{role: :error, content: "Agent stopped responding. Send a message to retry."},
          %{role: :assistant, content: "recovered again"}
        ]
      }

      assert EvalRunner.count_session_crashes(state) == 2
    end

    test "ignores :error messages that aren't session-death crashes" do
      state = %{
        messages: [
          %{role: :error, content: "bundle install failed"},
          %{role: :error, content: "database does not exist"}
        ]
      }

      assert EvalRunner.count_session_crashes(state) == 0
    end

    test "detects crash even when followup tool calls exist (the old bug)" do
      # This is exactly the shape that made the old
      # `List.last(messages)` check return false and burn a nudge:
      # the crash is buried under later tool/assistant messages.
      state = %{
        messages: [
          %{role: :user, content: "setup"},
          %{role: :error, content: "Agent stopped responding. Send a message to retry."},
          %{role: :assistant, content: "Trying to recover"},
          %{role: :tool, content: "exec echo hi"},
          %{role: :tool_result, content: "hi"}
        ]
      }

      assert EvalRunner.count_session_crashes(state) == 1
    end

    test "ignores messages with non-binary content without crashing" do
      state = %{
        messages: [
          %{role: :error, content: nil},
          %{role: :error, content: ["list content"]},
          %{role: :error, content: "Agent stopped responding. Send a message to retry."}
        ]
      }

      assert EvalRunner.count_session_crashes(state) == 1
    end
  end

  describe "has_real_project_files?/1" do
    # This is the classifier that decides whether the host→volume
    # sync has populated the workspace enough to let the agent start.
    # A false positive here lets the agent run against an empty
    # volume and bootstrap a bogus app (bookstack #7 did this).
    # A false negative just delays the eval.

    test "false on an empty volume" do
      listing = """
      total 8
      drwxr-xr-x    2 root     root          4096 Apr 15 15:04 .
      drwxr-xr-x    1 root     root          4096 Apr 15 15:04 ..
      """

      refute EvalRunner.has_real_project_files?(listing)
    end

    test "false when only the .loopyard config dir is present" do
      listing = """
      total 12
      drwxr-xr-x    3 root     root          4096 Apr 15 15:04 .
      drwxr-xr-x    1 root     root          4096 Apr 15 15:04 ..
      drwxr-xr-x    3 root     root          4096 Apr 15 15:04 .loopyard
      """

      refute EvalRunner.has_real_project_files?(listing)
    end

    test "true when real project files are present" do
      listing = """
      total 40
      drwxr-xr-x    7 root     root          4096 Apr 15 15:04 .
      drwxr-xr-x    1 root     root          4096 Apr 15 15:04 ..
      drwxr-xr-x    3 root     root          4096 Apr 15 15:04 .loopyard
      drwxr-xr-x    8 root     root          4096 Apr 15 15:04 .git
      -rw-r--r--    1 root     root           340 Apr 15 15:04 README.md
      drwxr-xr-x    2 root     root          4096 Apr 15 15:04 app
      """

      assert EvalRunner.has_real_project_files?(listing)
    end

    test "tolerates non-string input" do
      refute EvalRunner.has_real_project_files?(nil)
      refute EvalRunner.has_real_project_files?([])
    end
  end

  describe "wait_for_workspace_container/2" do
    test "times out when the container never comes up" do
      # A workspace_id we know has no container — the helper should
      # return {:error, :timeout} after the budget, not hang.
      assert {:error, :timeout} =
               EvalRunner.wait_for_workspace_container(
                 "wait-ctnr-test-#{:rand.uniform(1_000_000)}",
                 200
               )
    end
  end
end
