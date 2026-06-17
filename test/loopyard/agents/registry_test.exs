defmodule Loopyard.Agents.RegistryTest do
  use ExUnit.Case

  alias Loopyard.Agents.Registry

  describe "list/0 + get/1 with built-in agents" do
    test "ships a single self-determining built-in agent (coding)" do
      names = Registry.list() |> Enum.map(& &1.name)
      assert "Coding" in names
      # The old setup/coding split is gone — one agent decides at runtime.
      refute "Setup" in names
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
    test "the coding agent carries the setup playbook + stacks, excluding agent.md" do
      {:ok, agent} = Registry.get("coding")
      catalog = Registry.catalog(agent)

      assert "setup_guide.md" in catalog
      refute "agent.md" in catalog
      # Has at least one stack template
      assert Enum.any?(catalog, &String.starts_with?(&1, "stacks/"))
    end
  end

  describe "default_agent_name/0" do
    test "returns coding" do
      assert Registry.default_agent_name() == "coding"
    end
  end
end
