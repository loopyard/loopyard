defmodule BoomLooper.EvalRunnerTest do
  use ExUnit.Case, async: false

  alias BoomLooper.EvalRunner

  setup do
    BoomLooper.ProjectRegistry.ensure_ets_tables()
    BoomLooper.ChatAgent.ensure_ets_table()

    # Clean up projects from previous tests
    BoomLooper.ProjectRegistry.list_projects()
    |> Enum.each(&BoomLooper.ProjectRegistry.remove_project(&1.id))

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
    Map.merge(%{
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
    }, overrides)
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

      assert path =~ "evals/my_cool_project/runs/"
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
end
