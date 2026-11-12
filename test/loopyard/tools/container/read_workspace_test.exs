defmodule Loopyard.Tools.Container.ReadWorkspaceTest do
  @moduledoc """
  `read_workspace` is the one tool that reaches past a workspace's own volume,
  so its boundary is tested as a boundary: same project only, never the
  caller's own workspace, never secrets or plumbing — on the path asked for
  and on the path it resolves to.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Tools.Container.ReadWorkspace
  alias Loopyard.WorkspaceRegistry

  defp workspace(project_id, name) do
    id = "rw-#{System.unique_integer([:positive])}"

    WorkspaceRegistry.insert(id, %{
      id: id,
      project_id: project_id,
      name: name,
      branch: name,
      volume: "vol-#{id}",
      status: :stopped
    })

    on_exit(fn -> WorkspaceRegistry.delete(id) end)
    id
  end

  describe "resolve_target/2 (which workspaces a caller may read)" do
    setup do
      project = "rw-proj-#{System.unique_integer([:positive])}"
      other_project = "rw-other-#{System.unique_integer([:positive])}"

      %{
        me: workspace(project, "main"),
        sibling: workspace(project, "feature-x"),
        stranger: workspace(other_project, "main")
      }
    end

    test "a sibling of the same project, by id or by branch name", ctx do
      assert {:ok, %{id: id}} = ReadWorkspace.resolve_target(ctx.me, ctx.sibling)
      assert id == ctx.sibling
      assert {:ok, %{id: ^id}} = ReadWorkspace.resolve_target(ctx.me, " feature-x ")
    end

    test "another project's workspace is simply not found — by id or by name", ctx do
      assert {:error, msg} = ReadWorkspace.resolve_target(ctx.me, ctx.stranger)
      assert msg =~ "No other workspace"
      # The refusal lists only this project's siblings: nothing about the
      # other project beyond the caller's own input echoed back.
      [_, readable] = String.split(msg, "Readable: ")
      assert readable == "feature-x [#{ctx.sibling}]."

      # "main" names the caller's own branch here, never the other project's main.
      assert {:error, _} = ReadWorkspace.resolve_target(ctx.me, "main")
    end

    test "the caller's own workspace is refused (it has its own file tools)", ctx do
      assert {:error, msg} = ReadWorkspace.resolve_target(ctx.me, ctx.me)
      assert msg =~ "your own workspace"
    end

    test "garbage in is a clean error", ctx do
      assert {:error, _} = ReadWorkspace.resolve_target(ctx.me, nil)
      assert {:error, _} = ReadWorkspace.resolve_target("no-such-workspace", "feature-x")
    end
  end

  describe "allowed/1 (what may be read from a sibling)" do
    test "ordinary source is fine" do
      for path <-
            ~w(/workspace /workspace/README.md /workspace/app/models/user.rb /workspace/environment.rb) do
        assert ReadWorkspace.allowed(path) == :ok, path
      end
    end

    test "secrets and plumbing are refused wherever they sit in the tree" do
      for path <- ~w(
            /workspace/.env /workspace/.env.local /workspace/apps/api/.env.production
            /workspace/.git/config /workspace/vendor/lib/.git/HEAD
            /workspace/.loopyard/uploads/shot.png /workspace/.ssh/id_ed25519
            /workspace/certs/server.pem /workspace/deploy/prod.key /workspace/id_rsa
          ) do
        assert {:error, msg} = ReadWorkspace.allowed(path), path
        assert msg =~ "stay with the workspace that owns them"
      end
    end

    test "a path that RESOLVES outside the workspace is refused (the symlink case)" do
      assert {:error, msg} = ReadWorkspace.allowed("/etc/passwd")
      assert msg =~ "outside the workspace"
      assert {:error, _} = ReadWorkspace.allowed("/workspace-other/x")
    end
  end

  describe "parse/2 (the throwaway container's answer)" do
    test "file, directory, missing" do
      assert {:ok, :file, "/workspace/a.txt", "one\ntwo\n"} =
               ReadWorkspace.parse("/workspace/a.txt\nfile\none\ntwo\n", "/workspace/a.txt")

      assert {:ok, :dir, "/workspace/app", "models/\nuser.rb\n"} =
               ReadWorkspace.parse("/workspace/app\ndir\nmodels/\nuser.rb\n", "/workspace/app")

      assert {:ok, :file, "/workspace/empty", ""} =
               ReadWorkspace.parse("/workspace/empty\nfile", "/workspace/empty")

      assert {:error, msg} = ReadWorkspace.parse("__LY_MISSING__\n", "/workspace/nope.txt")
      assert msg =~ "nope.txt"
    end

    test "the RESOLVED path is what gets re-checked: a symlink to a secret reads as a refusal" do
      # `notes.txt -> .env`: the container reports the real path; allowed/1 on
      # it is what execute/2 gates the body on.
      assert {:ok, :file, real, _secret} =
               ReadWorkspace.parse("/workspace/.env\nfile\nTOKEN=shh\n", "/workspace/notes.txt")

      assert {:error, _} = ReadWorkspace.allowed(real)
    end
  end

  test "it is served to in-container agents, and only as a read" do
    assert ReadWorkspace in Loopyard.ChatAgent.ToolConfig.acp_control_plane_tools()
    source = File.read!("lib/loopyard/tools/container/read_workspace.ex")
    # Mounted read-only, no network, and never exec'd through the sibling's container.
    assert source =~ ~s|:/workspace:ro|
    assert source =~ ~s|"--network",\n           "none"|
    refute source =~ "exec_in"
  end
end
