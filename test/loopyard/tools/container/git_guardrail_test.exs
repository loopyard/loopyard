defmodule Loopyard.Tools.Container.GitGuardrailTest do
  @moduledoc """
  Pure tests for the `git push` guardrail classification. These are UX
  guardrails (an agent can bypass via `exec`), so the real point is that a
  legit feature-branch push is NEVER misclassified as dangerous, and the three
  dangerous shapes (force / remote-delete / push-to-default) ARE flagged.

  No Docker, no app boot — `classify_push/1` is pure.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Tools.Container.Git

  defp classify(cmd), do: Git.classify_push(OptionParser.split("push " <> cmd) |> tl())

  describe "force-push" do
    test "is flagged in every spelling" do
      assert Git.classify_push(~w(--force origin main)) == :force
      assert Git.classify_push(~w(-f origin feature)) == :force
      assert Git.classify_push(~w(--force-with-lease origin feature)) == :force
      # +refspec is a force push
      assert classify("origin +feature") == :force
    end
  end

  describe "remote-branch delete" do
    test "is flagged via flag or empty-source refspec" do
      assert Git.classify_push(~w(--delete origin feature)) == :delete
      assert Git.classify_push(~w(-d origin feature)) == :delete
      assert classify("origin :feature") == :delete
    end
  end

  describe "explicit target branch" do
    test "reads the REMOTE side of a local:remote refspec" do
      assert classify("origin HEAD:main") == {:target, "main"}
      assert classify("origin my-local:their-remote") == {:target, "their-remote"}
    end

    test "a bare branch refspec is its own target" do
      assert classify("origin feature") == {:target, "feature"}
      assert classify("origin main") == {:target, "main"}
    end
  end

  describe "current branch (needs a container read to resolve)" do
    test "bare push / push-remote yields :current" do
      assert Git.classify_push([]) == :current
      assert classify("origin") == :current
      assert classify("-u origin") == :current
    end
  end

  test "a normal feature push is a plain target, never dangerous" do
    # This is the case that MUST NOT be over-blocked.
    assert classify("origin cool-feature") == {:target, "cool-feature"}
    refute classify("origin cool-feature") in [:force, :delete]
  end
end
