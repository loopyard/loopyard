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
      model: claude-opus-5
      ---

      You are a Setup agent.
      """)

      assert {:ok, fields} = Loader.load(dir)
      assert fields.name == "Setup"
      assert fields.description == "Bootstrap a project"
      assert fields.model == "claude-opus-5"
      assert fields.body =~ "You are a Setup agent"
    end

    test "model is optional — nil means the loop's default", %{dir: dir} do
      File.write!(Path.join(dir, "agent.md"), """
      ---
      name: Test
      ---

      Body
      """)

      assert {:ok, %{model: nil, description: nil}} = Loader.load(dir)
    end

    test "rejects a non-string model", %{dir: dir} do
      File.write!(Path.join(dir, "agent.md"), """
      ---
      name: Test
      model: 3
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
