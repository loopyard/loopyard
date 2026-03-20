defmodule BoomLooper.Tools.ChecklistTest do
  use ExUnit.Case

  alias BoomLooper.Tools.Checklist

  describe "module structure" do
    test "is a valid MCP server" do
      assert ClaudeCode.MCP.Server.sdk_server?(Checklist)
    end

    test "has correct server name and 5 tools" do
      info = Checklist.__tool_server__()
      assert info.name == "boom-looper-checklist"
      assert length(info.tools) == 5
    end

    test "tool names match expected" do
      tool_names = Checklist.__tool_server__().tools |> Enum.map(& &1.__tool_name__())
      assert "list_checklists" in tool_names
      assert "start_checklist" in tool_names
      assert "get_progress" in tool_names
      assert "check_item" in tool_names
      assert "uncheck_item" in tool_names
    end
  end

  describe "do_list_checklists/1" do
    test "returns built-in checklists with nil project dir" do
      result = Checklist.do_list_checklists(nil)
      assert is_list(result)
      ids = Enum.map(result, & &1.id)
      assert "setup" in ids
      assert "feature" in ids
    end

    test "entries have id, name, and description" do
      [first | _] = Checklist.do_list_checklists(nil)
      assert Map.has_key?(first, :id)
      assert Map.has_key?(first, :name)
      assert Map.has_key?(first, :description)
    end
  end

  describe "do_start_checklist/2" do
    setup do
      id = "checklist-test-#{:rand.uniform(100_000)}"
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-cl-tool-#{id}")
      File.mkdir_p!(tmp_dir)

      # Start an agent so find_project_dir works
      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "CL Test",
          working_dir: tmp_dir,
          bind_mount: tmp_dir,
          started_by: "test"
        )

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        File.rm_rf!(tmp_dir)
        Process.sleep(50)
      end)

      %{agent_id: id, project_dir: tmp_dir}
    end

    test "starts a built-in checklist", %{agent_id: id} do
      assert {:ok, result} = Checklist.do_start_checklist(id, "setup")
      assert result.name == "Setup"
      assert result.active_path =~ ".hive/active/#{id}-setup.md"
      assert File.exists?(result.active_path)
    end

    test "returns error for nonexistent checklist", %{agent_id: id} do
      assert {:error, msg} = Checklist.do_start_checklist(id, "nonexistent")
      assert msg =~ "not found"
    end
  end

  describe "do_get_progress/1" do
    test "returns error when no active checklist" do
      # Use a fake agent ID that doesn't exist
      assert {:error, _} = Checklist.do_get_progress("no-such-agent")
    end
  end

  describe "do_check_item/2 and do_uncheck_item/2" do
    setup do
      id = "check-test-#{:rand.uniform(100_000)}"
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-cl-check-tool-#{id}")
      File.mkdir_p!(tmp_dir)

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Check Test",
          working_dir: tmp_dir,
          bind_mount: tmp_dir,
          started_by: "test"
        )

      # Start a checklist
      {:ok, result} = Checklist.do_start_checklist(id, "setup")

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        File.rm_rf!(tmp_dir)
        Process.sleep(50)
      end)

      %{agent_id: id, active_path: result.active_path}
    end

    test "check_item marks item done and get_progress reflects it", %{agent_id: id} do
      # Get initial progress
      {:ok, initial} = Checklist.do_get_progress(id)
      assert initial.checked == 0

      # Find an unchecked item line
      item = Enum.find(initial.items, &(!&1.checked))
      assert {:ok, _} = Checklist.do_check_item(id, item.line)

      # Verify progress updated
      {:ok, updated} = Checklist.do_get_progress(id)
      assert updated.checked == 1
    end

    test "uncheck_item reverses a check", %{agent_id: id} do
      {:ok, initial} = Checklist.do_get_progress(id)
      item = Enum.find(initial.items, &(!&1.checked))

      Checklist.do_check_item(id, item.line)
      {:ok, after_check} = Checklist.do_get_progress(id)
      assert after_check.checked == 1

      Checklist.do_uncheck_item(id, item.line)
      {:ok, after_uncheck} = Checklist.do_get_progress(id)
      assert after_uncheck.checked == 0
    end
  end
end
