defmodule BoomLooper.EvalRunnerTest do
  use ExUnit.Case, async: false

  alias BoomLooper.EvalRunner

  setup do
    BoomLooper.ProjectRegistry.ensure_ets_tables()
    BoomLooper.ChatAgent.ensure_ets_table()

    # Clean up projects from previous tests
    BoomLooper.ProjectRegistry.list_projects()
    |> Enum.each(&BoomLooper.ProjectRegistry.remove_project(&1.id))

    # Clean up eval output
    File.rm_rf("evals")

    on_exit(fn -> File.rm_rf("evals") end)
    :ok
  end

  defp base_result(overrides \\ %{}) do
    Map.merge(%{
      outcome: :completed,
      project_path: "/tmp/test-project",
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
      checklist_checked: 11,
      checklist_total: 11,
      tool_usage: %{}
    }, overrides)
  end

  describe "check_services/1" do
    test "returns empty map when no services running" do
      assert EvalRunner.check_services("/nonexistent/path") == %{}
    end
  end

  describe "record_run/2" do
    test "writes eval result to file" do
      result = base_result(%{
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
      assert content =~ "Checklist:** 11/11"
      assert content =~ "Read: 5"
    end

    test "sanitizes project name for directory" do
      result = base_result(%{
        outcome: :failed,
        project_path: "/tmp/My Cool Project!",
        project_name: "My Cool Project!",
        agent_id: "def456",
        status: :crashed
      })

      path = EvalRunner.record_run("My Cool Project!", result)

      assert path =~ "evals/my_cool_project"
      assert File.exists?(path)
    end

    test "records error messages and nudges" do
      result = base_result(%{
        outcome: :stalled,
        project_path: "/tmp/errored",
        project_name: "errored",
        agent_id: "err789",
        errors: 2,
        error_messages: ["CLI crashed", "Session lost"],
        nudges: 3,
        checklist_checked: 7,
        checklist_total: 11
      })

      path = EvalRunner.record_run("errored", result)
      content = File.read!(path)

      assert content =~ "CLI crashed"
      assert content =~ "Session lost"
      assert content =~ "Errors:** 2"
      assert content =~ "Nudges:** 3"
      assert content =~ "Checklist:** 7/11"
    end
  end
end
