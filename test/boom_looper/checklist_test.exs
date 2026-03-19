defmodule BoomLooper.ChecklistTest do
  use ExUnit.Case

  alias BoomLooper.Checklist

  @sample_md """
  # Setup

  Set up the development environment for this project.

  - [ ] Examine project files to detect language, framework, and tools
  - [ ] Generate `.hive/workspace.json` with Dockerfile, services, processes
  - [ ] Rebuild container with `rebuild` tool
  - [x] Start services (databases, caches) with `start_services`
  - [ ] Run project setup commands (install deps, migrate, seed)

  ## Notes
  - Use `save_workspace` to persist configuration
  """

  describe "parse/1" do
    test "extracts title from first heading" do
      checklist = Checklist.parse(@sample_md)
      assert checklist.name == "Setup"
    end

    test "extracts description" do
      checklist = Checklist.parse(@sample_md)
      assert checklist.description == "Set up the development environment for this project."
    end

    test "extracts items with correct checked status" do
      checklist = Checklist.parse(@sample_md)
      assert length(checklist.items) == 5

      assert Enum.at(checklist.items, 0).checked == false
      assert Enum.at(checklist.items, 0).text =~ "Examine project files"

      assert Enum.at(checklist.items, 3).checked == true
      assert Enum.at(checklist.items, 3).text =~ "Start services"
    end

    test "items have correct line numbers" do
      checklist = Checklist.parse(@sample_md)
      # Lines are 1-based, items start after title + blank + description + blank
      assert Enum.all?(checklist.items, fn item -> item.line > 0 end)
    end

    test "preserves raw markdown" do
      checklist = Checklist.parse(@sample_md)
      assert checklist.raw == @sample_md
    end

    test "handles empty markdown" do
      checklist = Checklist.parse("")
      assert checklist.name == nil
      assert checklist.description == nil
      assert checklist.items == []
    end

    test "handles markdown with no checklist items" do
      checklist = Checklist.parse("# Title\n\nJust some text.")
      assert checklist.name == "Title"
      assert checklist.items == []
    end
  end

  describe "progress/1" do
    test "returns checked and total counts" do
      checklist = Checklist.parse(@sample_md)
      assert Checklist.progress(checklist) == {1, 5}
    end

    test "returns {0, 0} for empty checklist" do
      checklist = Checklist.parse("# Empty\n\nNo items here.")
      assert Checklist.progress(checklist) == {0, 0}
    end

    test "returns correct counts when all checked" do
      md = "# Done\n\n- [x] First\n- [x] Second\n"
      checklist = Checklist.parse(md)
      assert Checklist.progress(checklist) == {2, 2}
    end
  end

  describe "load_file/1" do
    test "loads a checklist from a file" do
      tmp = Path.join(System.tmp_dir!(), "checklist-test-#{:rand.uniform(100_000)}.md")
      File.write!(tmp, @sample_md)
      on_exit(fn -> File.rm(tmp) end)

      assert {:ok, checklist} = Checklist.load_file(tmp)
      assert checklist.name == "Setup"
      assert checklist.source_path == tmp
      assert checklist.id == Path.basename(tmp, ".md")
      assert length(checklist.items) == 5
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = Checklist.load_file("/nonexistent/file.md")
    end
  end

  describe "available/1" do
    test "loads built-in checklists" do
      checklists = Checklist.available()
      ids = Enum.map(checklists, & &1.id)

      assert "setup" in ids
      assert "feature" in ids
    end

    test "project checklists override built-in ones" do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-cl-test-#{:rand.uniform(100_000)}")
      checklist_dir = Path.join(tmp_dir, ".hive/checklists")
      File.mkdir_p!(checklist_dir)

      File.write!(Path.join(checklist_dir, "setup.md"), """
      # Custom Setup

      A project-specific setup checklist.

      - [ ] Custom step one
      - [ ] Custom step two
      """)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checklists = Checklist.available(tmp_dir)
      setup = Enum.find(checklists, &(&1.id == "setup"))

      assert setup.name == "Custom Setup"
      assert length(setup.items) == 2
    end

    test "merges project and built-in checklists" do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-cl-test-#{:rand.uniform(100_000)}")
      checklist_dir = Path.join(tmp_dir, ".hive/checklists")
      File.mkdir_p!(checklist_dir)

      File.write!(Path.join(checklist_dir, "deploy.md"), """
      # Deploy

      Deploy the project.

      - [ ] Run deploy
      """)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checklists = Checklist.available(tmp_dir)
      ids = Enum.map(checklists, & &1.id)

      assert "setup" in ids
      assert "feature" in ids
      assert "deploy" in ids
    end
  end

  describe "instantiate/3" do
    test "copies template to active directory" do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-cl-inst-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checklist = Checklist.parse(@sample_md)
      checklist = %{checklist | id: "setup"}

      result = Checklist.instantiate(checklist, "agent123", tmp_dir)

      assert result.active_path =~ ".hive/active/agent123-setup.md"
      assert File.exists?(result.active_path)
      assert File.read!(result.active_path) == @sample_md
    end
  end

  describe "check_item/2 and uncheck_item/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "boom-looper-cl-check-#{:rand.uniform(100_000)}.md")

      File.write!(tmp, """
      # Test

      - [ ] First item
      - [ ] Second item
      - [x] Third item
      """)

      on_exit(fn -> File.rm(tmp) end)
      %{path: tmp}
    end

    test "check_item marks an unchecked item as checked", %{path: path} do
      assert :ok = Checklist.check_item(path, 3)
      {:ok, checklist} = Checklist.load_file(path)
      first = Enum.find(checklist.items, &(&1.text == "First item"))
      assert first.checked == true
    end

    test "uncheck_item marks a checked item as unchecked", %{path: path} do
      assert :ok = Checklist.uncheck_item(path, 5)
      {:ok, checklist} = Checklist.load_file(path)
      third = Enum.find(checklist.items, &(&1.text == "Third item"))
      assert third.checked == false
    end

    test "check_item on out-of-range line returns error", %{path: path} do
      assert {:error, :line_out_of_range} = Checklist.check_item(path, 999)
    end

    test "check_item on nonexistent file returns error" do
      assert {:error, :enoent} = Checklist.check_item("/nonexistent.md", 1)
    end
  end
end
