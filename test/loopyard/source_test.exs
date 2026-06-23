defmodule Loopyard.SourceTest do
  use ExUnit.Case, async: true

  alias Loopyard.Source

  describe "for_project/1" do
    test "dispatches :local → Source.Local" do
      assert Source.for_project(%{source_type: :local}) == Loopyard.Source.Local
    end

    test "dispatches :github → Source.GitHub" do
      assert Source.for_project(%{source_type: :github}) == Loopyard.Source.GitHub
    end

    test "falls back to GitHub when only git_url is set (legacy record)" do
      assert Source.for_project(%{git_url: "git@github.com:acme/thing.git"}) ==
               Loopyard.Source.GitHub
    end

    test "defaults to Local when nothing identifies the source" do
      assert Source.for_project(%{}) == Loopyard.Source.Local
    end
  end

  describe "supports_git?/1" do
    test "returns true for Source.Local" do
      assert Source.supports_git?(Loopyard.Source.Local)
    end

    test "GitHub git ops route to container git (no longer stubbed)" do
      # GitHub workspaces have no host worktree — git runs in the container against
      # the code volume. With no workspace id there's nothing to reach, so we get a
      # plain error tuple: NOT :not_implemented, and no crash.
      assert {:error, msg} = Loopyard.Source.GitHub.git_log(nil, %{}, [])
      assert is_binary(msg)
      assert {:error, _} = Loopyard.Source.GitHub.git_status(nil, %{})
      assert {:error, _} = Loopyard.Source.GitHub.git_diff(nil, %{}, [])
      assert {:error, _} = Loopyard.Source.GitHub.git_show(nil, %{}, "HEAD", "f")
    end
  end
end
