defmodule Loopyard.Harness.ACPLaunchSubagentModelTest do
  @moduledoc """
  The per-agent sub-agent model reaches the harness the way its Catalog entry
  says — for Claude Code, `CLAUDE_CODE_SUBAGENT_MODEL` (+ `_FORCE`) exported at
  launch, which the adapter passes through to the CLI it spawns — and a harness
  without the knob (Codex) gets nothing, as does an id the harness doesn't list.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Harness.{ACP, Catalog}

  test "Claude: exports the model and FORCE, after ~/.profile" do
    cmd = ACP.docker_exec_cmd("work-1", :claude, subagent_model: "sonnet")

    assert cmd =~ ~s(export CLAUDE_CODE_SUBAGENT_MODEL="sonnet";)
    assert cmd =~ ~s(export CLAUDE_CODE_SUBAGENT_MODEL_FORCE="1";)

    {profile_at, _} = :binary.match(cmd, ~S(. "$HOME/.profile"))
    {model_at, _} = :binary.match(cmd, "CLAUDE_CODE_SUBAGENT_MODEL=")
    assert profile_at < model_at, "exported after ~/.profile so it wins"
  end

  test "nil (same as the agent) exports nothing" do
    refute ACP.docker_exec_cmd("work-1", :claude) =~ "SUBAGENT"
    refute ACP.docker_exec_cmd("work-1", :claude, subagent_model: nil) =~ "SUBAGENT"
  end

  test "a harness with no knob exports nothing" do
    refute ACP.docker_exec_cmd("work-1", :codex, subagent_model: "sonnet") =~ "SUBAGENT"
  end

  test "an id the harness doesn't list never reaches the launch script" do
    refute ACP.docker_exec_cmd("work-1", :claude, subagent_model: "x'; rm -rf / #") =~ "SUBAGENT"
  end

  describe "Catalog" do
    test "the control's options lead with 'Same as the agent', then the picker's models" do
      assert [{"", "Same as the agent"} | rest] = Catalog.subagent_model_options(:claude)
      assert rest == Catalog.fetch(:claude).models
    end

    test "Codex offers no control" do
      refute Catalog.subagent_model?(:codex)
      assert Catalog.subagent_model_options(:codex) == []
      assert Catalog.subagent_model_env(:codex, "sonnet") == []
    end
  end
end
