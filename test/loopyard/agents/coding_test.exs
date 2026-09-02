defmodule Loopyard.Agents.CodingTest do
  use ExUnit.Case, async: true

  alias Loopyard.Agents.Coding

  describe "folder/0" do
    test "returns a real directory containing agent.md" do
      folder = Coding.folder()
      assert File.dir?(folder)
      assert File.exists?(Path.join(folder, "agent.md"))
    end
  end

  describe "definition/0" do
    test "loads the agent definition with a non-empty body" do
      assert {:ok, agent} = Coding.definition()
      assert %Loopyard.Agents.Agent{} = agent
      assert is_binary(agent.body)
      assert String.trim(agent.body) != ""
    end
  end

  describe "catalog/0" do
    test "returns sorted relative paths excluding agent.md and Dockerfile" do
      catalog = Coding.catalog()

      assert is_list(catalog)
      assert catalog == Enum.sort(catalog)
      refute "agent.md" in catalog
      refute "Dockerfile" in catalog
      # Carries the setup playbook + at least one stack template.
      assert "setup_guide.md" in catalog
      assert Enum.any?(catalog, &String.starts_with?(&1, "stacks/"))
    end
  end
end
