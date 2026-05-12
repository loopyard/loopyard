defmodule Loopyard.ChatAgent.ClaudeContextTest do
  @moduledoc """
  ClaudeContext is the bridge that makes a GitHub (volume-only) workspace
  behave like a Local one from the Claude Code CLI's perspective.

  Contract:

    * Mirror well-known files (`CLAUDE.md`, `.claude/settings.json`, …)
      from the code volume into `working_dir`.
    * Follow `@path/to/file.md` imports inside the CLAUDE.md family so
      the CLI can resolve them from the mirrored copy.
    * Never clobber a `working_dir` that already has a `CLAUDE.md` —
      that's a Local workspace where the host is the source of truth.
    * Fail soft: missing volume, unreadable file — `:skip` or
      `{:error, _}`, never a raise.

  Tests swap `Loopyard.VolumeIO` for `Loopyard.Test.FakeVolumeIO`
  via `Application.put_env/3` so we don't need Docker.
  """
  use ExUnit.Case, async: false

  alias Loopyard.ChatAgent.ClaudeContext
  alias Loopyard.Test.FakeVolumeIO

  @moduletag :tmp_dir

  setup do
    prior = Application.get_env(:loopyard, :volume_reader)
    Application.put_env(:loopyard, :volume_reader, FakeVolumeIO)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:loopyard, :volume_reader, prior),
        else: Application.delete_env(:loopyard, :volume_reader)
    end)

    :ok
  end

  describe "mirror/2" do
    test "skips when working_dir is missing" do
      assert :skip = ClaudeContext.mirror("ws-missing", "/nope/does/not/exist")
    end

    test "skips when host already has CLAUDE.md (unknown source, fallback)", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "CLAUDE.md"), "host copy")
      ws_id = seed_ws([{"CLAUDE.md", "volume copy"}])

      assert :skip = ClaudeContext.mirror(ws_id, dir)
      assert File.read!(Path.join(dir, "CLAUDE.md")) == "host copy"
    end

    test "skips for Local workspaces even when volume has CLAUDE.md", %{tmp_dir: dir} do
      ws_id = seed_ws([{"CLAUDE.md", "volume copy"}])
      register_project(ws_id, :local)

      assert :skip = ClaudeContext.mirror(ws_id, dir)
      refute File.exists?(Path.join(dir, "CLAUDE.md"))
    end

    test "re-mirrors for GitHub workspaces even when host has CLAUDE.md", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "CLAUDE.md"), "stale host copy")
      ws_id = seed_ws([{"CLAUDE.md", "fresh volume copy"}])
      register_project(ws_id, :github)

      assert {:ok, paths} = ClaudeContext.mirror(ws_id, dir)
      assert "CLAUDE.md" in paths
      assert File.read!(Path.join(dir, "CLAUDE.md")) == "fresh volume copy"
    end

    test "writes top-level CLAUDE.md from the volume", %{tmp_dir: dir} do
      ws_id = seed_ws([{"CLAUDE.md", "# My Project\nRules live here."}])

      assert {:ok, paths} = ClaudeContext.mirror(ws_id, dir)
      assert "CLAUDE.md" in paths
      assert File.read!(Path.join(dir, "CLAUDE.md")) =~ "Rules live here"
    end

    test "writes .claude/ well-known files", %{tmp_dir: dir} do
      ws_id =
        seed_ws([
          {"CLAUDE.md", "main"},
          {".claude/CLAUDE.md", "project-scoped"},
          {".claude/settings.json", ~s({"key":"value"})}
        ])

      assert {:ok, paths} = ClaudeContext.mirror(ws_id, dir)
      assert ".claude/CLAUDE.md" in paths
      assert ".claude/settings.json" in paths
      assert File.read!(Path.join(dir, ".claude/CLAUDE.md")) == "project-scoped"
    end

    test "resolves @imports relative to the importing file", %{tmp_dir: dir} do
      ws_id =
        seed_ws([
          {"CLAUDE.md", "See rules in @docs/RULES.md and @docs/STYLE.md"},
          {"docs/RULES.md", "# Rules"},
          {"docs/STYLE.md", "# Style"}
        ])

      assert {:ok, paths} = ClaudeContext.mirror(ws_id, dir)
      assert "docs/RULES.md" in paths
      assert "docs/STYLE.md" in paths
      assert File.read!(Path.join(dir, "docs/RULES.md")) == "# Rules"
    end

    test "follows nested imports up to the hop limit", %{tmp_dir: dir} do
      ws_id =
        seed_ws([
          {"CLAUDE.md", "@a.md"},
          {"a.md", "@b.md"},
          {"b.md", "@c.md"},
          {"c.md", "leaf"}
        ])

      assert {:ok, paths} = ClaudeContext.mirror(ws_id, dir)
      assert "a.md" in paths
      assert "b.md" in paths
      assert "c.md" in paths
    end

    test "ignores missing imports gracefully", %{tmp_dir: dir} do
      ws_id = seed_ws([{"CLAUDE.md", "@missing/file.md and some text"}])

      assert {:ok, ["CLAUDE.md"]} = ClaudeContext.mirror(ws_id, dir)
      refute File.exists?(Path.join(dir, "missing/file.md"))
    end

    test "refuses paths that climb above the workspace root", %{tmp_dir: dir} do
      ws_id = seed_ws([{"CLAUDE.md", "@../../etc/passwd"}])
      # Escape path must never be written.
      ClaudeContext.mirror(ws_id, dir)
      refute File.exists?(Path.join(dir, "../../etc/passwd"))
    end

    test "returns :skip when the volume has nothing", %{tmp_dir: dir} do
      ws_id = seed_ws([])
      assert :skip = ClaudeContext.mirror(ws_id, dir)
    end

    test "mirrors the full .claude/ tree including skills", %{tmp_dir: dir} do
      ws_id =
        seed_ws([
          {"CLAUDE.md", "main"},
          {".claude/skills/review-pr/SKILL.md", "# Review PR skill"},
          {".claude/skills/review-pr/helpers.sh", "echo hi"},
          {".claude/commands/deploy.md", "/deploy command"},
          {".claude/agents/tester.md", "testing agent"}
        ])

      {:ok, paths} = ClaudeContext.mirror(ws_id, dir)
      assert ".claude/skills/review-pr/SKILL.md" in paths
      assert ".claude/commands/deploy.md" in paths
      assert ".claude/agents/tester.md" in paths

      assert File.read!(Path.join(dir, ".claude/skills/review-pr/SKILL.md")) =~ "Review PR"
      assert File.read!(Path.join(dir, ".claude/commands/deploy.md")) =~ "deploy"
    end
  end

  # --- Helpers ---

  defp seed_ws(files) do
    ws_id = "ctx-#{System.unique_integer([:positive])}"
    volume = Loopyard.VolumeManager.code_volume_name(ws_id)
    FakeVolumeIO.seed(volume, files)
    ws_id
  end

  # Register a fake project + workspace so ClaudeContext's
  # ProjectRegistry lookup returns a source_type. We insert directly
  # into ETS since we just need the reads to succeed.
  defp register_project(ws_id, source_type) do
    Loopyard.StateKeeper.ensure_tables!()
    project_id = "proj-#{ws_id}"

    :ets.insert(
      :project_registry,
      {project_id, %{id: project_id, source_type: source_type, name: "fake"}}
    )

    :ets.insert(
      :workspace_registry,
      {ws_id, %{id: ws_id, project_id: project_id, name: "fake-ws", path: "/tmp/fake"}}
    )

    on_exit(fn ->
      :ets.delete(:project_registry, project_id)
      :ets.delete(:workspace_registry, ws_id)
    end)
  end
end
