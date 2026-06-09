defmodule Loopyard.Agent.Backend.ACP.SystemPromptTest do
  use ExUnit.Case, async: true

  alias Loopyard.Agent.Backend.ACP.SystemPrompt

  setup do
    dir = Path.join(System.tmp_dir!(), "acp-sp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp read_local(dir), do: File.read!(Path.join(dir, "CLAUDE.local.md"))

  test "installs the prompt into a managed CLAUDE.local.md block", %{dir: dir} do
    assert :ok = SystemPrompt.install(dir, "You are a Loopyard agent.")
    content = read_local(dir)
    assert content =~ "You are a Loopyard agent."
    assert content =~ "LOOPYARD AGENT INSTRUCTIONS"
    assert content =~ "END LOOPYARD AGENT INSTRUCTIONS"
    # Plain-text sentinels, NOT HTML comments (the harness ignores comments).
    refute content =~ "<!--"
  end

  test "does not touch a sibling project CLAUDE.md", %{dir: dir} do
    File.write!(Path.join(dir, "CLAUDE.md"), "PROJECT RULES\n")
    SystemPrompt.install(dir, "loopyard rules")
    assert File.read!(Path.join(dir, "CLAUDE.md")) == "PROJECT RULES\n"
  end

  test "preserves pre-existing CLAUDE.local.md content outside the managed block", %{dir: dir} do
    File.write!(Path.join(dir, "CLAUDE.local.md"), "my personal local notes\n")
    SystemPrompt.install(dir, "loopyard rules")
    content = read_local(dir)
    assert content =~ "my personal local notes"
    assert content =~ "loopyard rules"
  end

  test "is idempotent — re-installing replaces the block, no duplication", %{dir: dir} do
    SystemPrompt.install(dir, "first version")
    SystemPrompt.install(dir, "second version")
    content = read_local(dir)

    refute content =~ "first version"
    assert content =~ "second version"
    # exactly one managed block
    assert content |> String.split("(managed — do not edit)") |> length() == 2
  end

  test "render_file is pure and clobber-safe (for volume writers)" do
    out = SystemPrompt.render_file("keep me", "new prompt")
    assert out =~ "keep me"
    assert out =~ "new prompt"
    # re-rendering over its own output stays single-block
    out2 = SystemPrompt.render_file(out, "newer")
    refute out2 =~ "new prompt"
    assert out2 =~ "newer"
    assert out2 =~ "keep me"
  end
end
