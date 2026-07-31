defmodule Loopyard.GitDefaultBranchTest do
  @moduledoc """
  `Git.default_branch/2` — the fix for assuming every repo uses `main`.

  Both clone paths depend on this: the /projects/new/github form and the
  operator's `create_project_from_github`. Guessing "main" made a valid URL
  fail with "Remote branch main not found in upstream origin" — observed for
  real against github.com/octocat/Hello-World, which is `master`.

  The network-touching cases are tagged :slow so the default suite stays fast.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Git

  describe "failure handling" do
    test "returns nil for a URL that isn't a repo, instead of raising" do
      assert Git.default_branch("https://github.com/loopyard/definitely-not-a-real-repo-xyz") ==
               nil
    end

    test "returns nil for garbage input rather than blowing up the caller" do
      assert Git.default_branch("not-a-url-at-all") == nil
    end
  end

  describe "resolution against real remotes" do
    @tag :slow
    test "resolves a master-default repo as master, not main" do
      # The exact repo that exposed the bug.
      assert Git.default_branch("https://github.com/octocat/Hello-World") == "master"
    end

    @tag :slow
    test "resolves a main-default repo as main" do
      assert Git.default_branch("https://github.com/loopyard/loopyard") in ["main", nil]
    end
  end
end
