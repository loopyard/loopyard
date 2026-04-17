defmodule BoomLooper.Agents.RegistryTest do
  use ExUnit.Case

  alias BoomLooper.Agents.Registry

  describe "list/0 + get/1 with built-in agents" do
    test "lists built-in agents (setup + coding)" do
      agents = Registry.list()
      names = Enum.map(agents, & &1.name)
      assert "Setup" in names
      assert "Coding" in names
    end

    test "get/1 loads the setup agent" do
      assert {:ok, agent} = Registry.get("setup")
      assert agent.name == "Setup"
      assert agent.body =~ "Setup agent"
    end

    test "get/1 loads the coding agent" do
      assert {:ok, agent} = Registry.get("coding")
      assert agent.name == "Coding"
    end

    test "get/1 returns error for unknown agent" do
      assert {:error, _reason} = Registry.get("nonexistent")
    end

    test "rejects names with path traversal" do
      assert :error = Registry.folder_for("../../../etc")
      assert :error = Registry.folder_for("foo/bar")
      assert :error = Registry.folder_for(".hidden")
      assert :error = Registry.folder_for("")
    end
  end

  describe "catalog/1" do
    test "lists files in the setup folder, excluding agent.md" do
      {:ok, agent} = Registry.get("setup")
      catalog = Registry.catalog(agent)

      assert "setup_guide.md" in catalog
      refute "agent.md" in catalog
      # Has at least one stack template
      assert Enum.any?(catalog, &String.starts_with?(&1, "stacks/"))
    end

    test "coding agent has an empty catalog (just agent.md)" do
      {:ok, agent} = Registry.get("coding")
      assert Registry.catalog(agent) == []
    end
  end

  describe "default_agent_name/0" do
    test "returns coding" do
      assert Registry.default_agent_name() == "coding"
    end
  end
end
