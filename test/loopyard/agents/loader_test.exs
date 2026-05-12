defmodule Loopyard.Agents.LoaderTest do
  use ExUnit.Case

  alias Loopyard.Agents.Loader

  setup do
    dir = Path.join(System.tmp_dir!(), "agents_loader_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  describe "load/1" do
    test "parses frontmatter and body", %{dir: dir} do
      File.write!(Path.join(dir, "agent.md"), """
      ---
      name: Setup
      description: Bootstrap a project
      model: opus
      tools:
        - boom-looper-browser
      ---

      You are a Setup agent.
      """)

      assert {:ok, agent} = Loader.load(dir)
      assert agent.name == "Setup"
      assert agent.description == "Bootstrap a project"
      assert agent.model == "opus"
      assert agent.tools == ["boom-looper-browser"]
      assert agent.body =~ "You are a Setup agent"
      assert agent.folder == dir
    end

    test "defaults model to sonnet when omitted", %{dir: dir} do
      File.write!(Path.join(dir, "agent.md"), """
      ---
      name: Test
      ---

      Body
      """)

      assert {:ok, agent} = Loader.load(dir)
      assert agent.model == "sonnet"
      assert agent.tools == []
    end

    test "rejects invalid model alias", %{dir: dir} do
      File.write!(Path.join(dir, "agent.md"), """
      ---
      name: Test
      model: claude-3-turbo
      ---

      Body
      """)

      assert {:error, reason} = Loader.load(dir)
      assert reason =~ "invalid model"
    end

    test "requires name in frontmatter", %{dir: dir} do
      File.write!(Path.join(dir, "agent.md"), """
      ---
      description: Missing name
      ---

      Body
      """)

      assert {:error, reason} = Loader.load(dir)
      assert reason =~ "name"
    end

    test "rejects missing frontmatter", %{dir: dir} do
      File.write!(Path.join(dir, "agent.md"), "Just a body with no frontmatter")

      assert {:error, reason} = Loader.load(dir)
      assert reason =~ "frontmatter"
    end

    test "returns file error when agent.md missing", %{dir: dir} do
      assert {:error, _reason} = Loader.load(dir)
    end
  end
end
