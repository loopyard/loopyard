defmodule Loopyard.Agents.TemplateTest do
  use ExUnit.Case, async: true

  alias Loopyard.Agents.Template

  test "the two presets stamp the on-disk bodies with their composition" do
    coding = Template.coding()
    assert %Template{id: "coding", compute: :workspace, tools: :workspace, loop: :acp} = coding
    assert coding.name == "Coding"
    assert coding.body =~ "/workspace"
    assert coding.context == ["workspace-tools", "decisions"]
    assert File.dir?(coding.folder)

    system = Template.system()
    assert %Template{id: "system", compute: :workstation, tools: :system, loop: :acp} = system
    assert system.name == "System"
    assert system.body =~ "recall_conversation"
    assert system.body =~ "dispatch"
    refute system.body =~ "/workspace"
    assert system.context == ["decisions", "phone-screen"]
  end

  test "scope and MCP scope follow the composition" do
    assert Template.scope(Template.coding()) == :workspace
    assert Template.scope(Template.system()) == :system
    assert Template.mcp_scope(Template.system()) == :system
    refute Template.system?(Template.coding())
    assert Template.system?(Template.system())
  end

  test "all/0, fetch/1, exists?/1 know exactly the presets" do
    assert Enum.map(Template.all(), & &1.id) == ["coding", "system"]
    assert {:ok, %Template{id: "system"}} = Template.fetch("system")
    assert {:error, :unknown_template} = Template.fetch("nope")
    assert Template.exists?("coding")
    refute Template.exists?("a1b2c3d4e5f60718")
    assert_raise ArgumentError, fn -> Template.fetch!("nope") end
  end

  test "shared blocks load in the template's order and are non-empty" do
    [tools, decisions] = Template.blocks(Template.coding())
    assert tools =~ "loopyard-container MCP tools"
    assert decisions =~ "THE READER IS STATELESS"

    [decisions2, phone] = Template.blocks(Template.system())
    assert decisions2 == decisions
    assert phone =~ "END EVERY TURN BY CALLING"
  end

  test "the catalog lists the support files, not agent.md" do
    files = Template.catalog(Template.coding())
    assert "setup_guide.md" in files
    assert Enum.any?(files, &String.starts_with?(&1, "stacks/"))
    refute "agent.md" in files
    assert files == Enum.sort(files)
    assert Template.catalog(Template.system()) == []
  end
end
