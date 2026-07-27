defmodule Loopyard.Harness.ACP.SystemPromptTest do
  use ExUnit.Case, async: true

  alias Loopyard.Harness.ACP.SystemPrompt

  @begin "=== LOOPYARD AGENT INSTRUCTIONS (managed — do not edit) ==="
  @stop "=== END LOOPYARD AGENT INSTRUCTIONS ==="

  defp occurrences(content, sentinel) do
    length(String.split(content, sentinel)) - 1
  end

  describe "render_file/2" do
    test "fresh render contains only the managed block" do
      rendered = SystemPrompt.render_file("", "You are the agent.")

      assert rendered == @begin <> "\n\nYou are the agent.\n\n" <> @stop <> "\n"
      assert occurrences(rendered, @begin) == 1
      assert occurrences(rendered, @stop) == 1
    end

    test "sentinels are plain text, not HTML comments" do
      rendered = SystemPrompt.render_file("", "prompt")

      refute rendered =~ "<!--"
      refute rendered =~ "-->"
    end

    test "re-render REPLACES the managed block — idempotent, no duplication" do
      first = SystemPrompt.render_file("", "prompt version one")
      second = SystemPrompt.render_file(first, "prompt version two")

      assert occurrences(second, @begin) == 1
      assert occurrences(second, @stop) == 1
      assert second =~ "prompt version two"
      refute second =~ "prompt version one"

      # Re-rendering with the same prompt is a fixpoint.
      assert SystemPrompt.render_file(second, "prompt version two") == second
    end

    test "pre-existing user content outside the block is preserved" do
      existing = "# My local notes\n\nDon't touch the flux capacitor.\n"

      rendered = SystemPrompt.render_file(existing, "the managed prompt")

      assert String.starts_with?(rendered, "# My local notes")
      assert rendered =~ "Don't touch the flux capacitor."
      assert rendered =~ @begin
      assert rendered =~ "the managed prompt"

      # And it survives a re-render too.
      again = SystemPrompt.render_file(rendered, "a newer managed prompt")
      assert again =~ "Don't touch the flux capacitor."
      assert again =~ "a newer managed prompt"
      refute again =~ "the managed prompt"
      assert occurrences(again, @begin) == 1
    end

    test "a multiline prompt body round-trips (strip regex is /s)" do
      prompt = "Line one.\n\nLine two after a blank.\nLine three."
      existing = "user content stays\n"

      rendered = SystemPrompt.render_file(existing, prompt)
      assert rendered =~ prompt

      # The multiline block — newlines and all — is fully stripped on
      # re-render; only the replacement remains.
      replaced = SystemPrompt.render_file(rendered, "replacement prompt")

      assert replaced =~ "user content stays"
      assert replaced =~ "replacement prompt"
      refute replaced =~ "Line one."
      refute replaced =~ "Line two after a blank."
      refute replaced =~ "Line three."
      assert occurrences(replaced, @begin) == 1
      assert occurrences(replaced, @stop) == 1
    end

    test "prompt whitespace is trimmed into the block" do
      rendered = SystemPrompt.render_file("", "\n\n  padded prompt  \n\n")

      assert rendered == @begin <> "\n\npadded prompt\n\n" <> @stop <> "\n"
    end
  end

  describe "filename/0" do
    test "targets CLAUDE.local.md" do
      assert SystemPrompt.filename() == "CLAUDE.local.md"
    end
  end
end
