defmodule Loopyard.Harness.CatalogTest do
  @moduledoc """
  The harness catalog is the only place vendor vocabulary lives, so these tests
  guard the two things a wrong entry breaks silently: launching the wrong
  adapter, and one harness's orphan sweep killing another's live adapter.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Harness.ACP
  alias Loopyard.Harness.Catalog

  describe "lookup" do
    test "resolves by atom and by string (params round-trip through JSON)" do
      assert Catalog.fetch(:codex).adapter == "codex-acp"
      assert Catalog.fetch("codex").adapter == "codex-acp"
    end

    test "an unknown or missing harness falls back to the default rather than raising" do
      # A persisted agent naming a harness we've since removed must still boot.
      assert Catalog.fetch("wingardium").id == Catalog.default()
      assert Catalog.fetch(nil).id == Catalog.default()
      assert Catalog.default() == :claude
    end

    test "every entry has a distinct adapter binary" do
      adapters = Enum.map(Catalog.all(), & &1.adapter)
      assert adapters == Enum.uniq(adapters)
    end
  end

  describe "credentialed?/2 (advisory)" do
    test "true when any of the harness's keys holds a non-empty value" do
      assert Catalog.credentialed?(:claude, %{"CLAUDE_CODE_OAUTH_TOKEN" => "sk-x"})
      assert Catalog.credentialed?(:claude, %{"ANTHROPIC_API_KEY" => "sk-x"})
      assert Catalog.credentialed?(:codex, %{"OPENAI_API_KEY" => "sk-x"})
      assert Catalog.credentialed?(:codex, %{"CODEX_API_KEY" => "sk-x"})
    end

    test "blank and absent values do not count" do
      refute Catalog.credentialed?(:codex, %{"OPENAI_API_KEY" => "   "})
      refute Catalog.credentialed?(:codex, %{})
      refute Catalog.credentialed?(:codex, %{"CLAUDE_CODE_OAUTH_TOKEN" => "sk-x"})
    end
  end

  describe "docker_exec_cmd/2" do
    test "launches the harness's own adapter" do
      assert ACP.docker_exec_cmd("work-1", :codex) =~ "codex-acp"
      assert ACP.docker_exec_cmd("work-1", :claude) =~ "claude-agent-acp"
    end

    test "the orphan sweep is scoped to the harness's own processes" do
      # Both adapters can be live in one work container. A sweep that grepped a
      # shared marker would let a Codex launch reap a running Claude adapter.
      codex = ACP.docker_exec_cmd("work-1", :codex)
      claude = ACP.docker_exec_cmd("work-1", :claude)

      assert codex =~ ~s|grep -qa codex "$d/cmdline"|
      assert claude =~ ~s|grep -qa claude "$d/cmdline"|
    end

    test "the orphan sweep is scoped to the launching AGENT, so siblings survive" do
      # Every agent in a workspace shares one work container, and a sibling's
      # healthy adapter is "old" by the age guard — an unscoped sweep kill -9'd
      # it on every (re)start of any other agent.
      cmd = ACP.docker_exec_cmd("work-1", :claude, agent: "abc123")

      # Take a process only if it carries THIS agent's stamp, or no stamp at all
      # (an orphan from before stamps existed)…
      assert cmd =~ ~s|grep -qa "LOOPYARD_AGENT=abc123" "$d/environ"|
      assert cmd =~ ~s(|| ! grep -qa "LOOPYARD_AGENT=" "$d/environ")
      # …and stamp this launch's own tree, before the adapter is exec'd.
      assert cmd =~ "export LOOPYARD_AGENT=abc123; "
      stamp_at = :binary.match(cmd, "export LOOPYARD_AGENT") |> elem(0)
      exec_at = :binary.match(cmd, "exec \"$h\"") |> elem(0)
      assert stamp_at < exec_at

      # Without an agent the sweep is by harness alone (the old behaviour).
      refute ACP.docker_exec_cmd("work-1", :claude) =~ "LOOPYARD_AGENT"

      # The id goes into a single-quoted sh -c: nothing outside its charset.
      assert_raise ArgumentError, fn ->
        ACP.docker_exec_cmd("work-1", :claude, agent: "x'; rm -rf / #")
      end
    end

    test "every launch carries this instance's marker, and boot reaps by it alone" do
      marker = ACP.instance_marker()
      assert marker =~ ~r/\Aloopyard-instance=[0-9a-f]{12}\z/

      # An inert no-op at the head of the script: visible in host `ps`,
      # harness-agnostic (Codex clients are reaped too).
      for harness <- [:claude, :codex] do
        assert ACP.docker_exec_cmd("work-1", harness) =~ "sh -c ': #{marker}; "
      end

      # Boot must reap only ITS OWN stale clients — never by adapter name,
      # which matched every Loopyard on the machine.
      app = File.read!("lib/loopyard/application.ex")
      assert app =~ "Loopyard.Harness.ACP.instance_marker()"
      refute app =~ ~s|["-f", "claude-|
    end

    test "harness-specific env is exported after ~/.profile so it wins" do
      cmd = ACP.docker_exec_cmd("work-1", :codex)

      # Headless container: without NO_BROWSER the adapter offers a ChatGPT
      # browser login nobody can complete.
      assert cmd =~ ~s|export NO_BROWSER="1"|
      assert String.contains?(cmd, ".profile")

      profile_at = :binary.match(cmd, ".profile") |> elem(0)
      export_at = :binary.match(cmd, "export NO_BROWSER") |> elem(0)
      assert export_at > profile_at
    end

    test "still runs through docker exec (containment holds for every harness)" do
      for harness <- Catalog.all() do
        assert ACP.docker_exec_cmd("work-1", harness.id) =~ "docker exec -i work-1"
      end
    end

    # Codex reads AGENTS.md, not CLAUDE.local.md — the brief has to ride the
    # launch. It's prose (quotes, apostrophes, `$`) inside a single-quoted
    # `sh -c`, so it travels base64-encoded and is decoded in the container.
    test "the agent brief reaches Codex as developer_instructions via CODEX_CONFIG" do
      brief = ~s|YOUR AGENT ID: abc — don't "guess"; $HOME is the volume|
      cmd = ACP.docker_exec_cmd("work-1", :codex, brief: brief)

      assert [_, encoded] =
               Regex.run(
                 ~r/export CODEX_CONFIG="\$\(printf %s ([A-Za-z0-9+\/=]+) \| base64 -d\)"/,
                 cmd
               )

      config = encoded |> Base.decode64!() |> Jason.decode!()
      assert config["developer_instructions"] == brief
      # Static harness config rides along: a CLAUDE.md-only repo guides Codex too.
      assert config["project_doc_fallback_filenames"] == ["CLAUDE.md"]

      # Nothing from the brief leaks into the shell script itself.
      refute cmd =~ "YOUR AGENT ID"
    end

    # claude-agent-acp 0.76 rejects a model outside the session's list with
    # "Internal error" — observed live for Fable 5.1 and Opus 4.8, both in the
    # picker. The launch env is what puts every picker id on that list.
    test "Claude's launch allowlists every picker model" do
      cmd = ACP.docker_exec_cmd("work-1", :claude)

      assert [_, encoded] =
               Regex.run(
                 ~r/export CLAUDE_MODEL_CONFIG="\$\(printf %s ([A-Za-z0-9+\/=]+) \| base64 -d\)"/,
                 cmd
               )

      ids = Enum.map(Catalog.fetch(:claude).models, &elem(&1, 0))
      assert Jason.decode!(Base.decode64!(encoded)) == %{"availableModels" => ids}

      # The one id Claude Code 2.1.257 drops from availableModels.
      assert cmd =~ ~s|export ANTHROPIC_CUSTOM_MODEL_OPTION="claude-fable-5-1"|
      assert "claude-fable-5-1" in ids
    end

    test "the brief stays a cwd file for Claude — no config env" do
      refute ACP.docker_exec_cmd("work-1", :claude, brief: "hello") =~ "CODEX_CONFIG"
    end

    test "Codex with no brief still gets its static config" do
      cmd = ACP.docker_exec_cmd("work-1", :codex)
      assert cmd =~ "export CODEX_CONFIG="
      [_, encoded] = Regex.run(~r/printf %s ([A-Za-z0-9+\/=]+) \| base64 -d/, cmd)

      refute Map.has_key?(
               encoded |> Base.decode64!() |> Jason.decode!(),
               "developer_instructions"
             )
    end
  end
end
