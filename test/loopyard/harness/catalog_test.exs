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
  end
end
