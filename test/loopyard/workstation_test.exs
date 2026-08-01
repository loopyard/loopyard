defmodule Loopyard.WorkstationTest do
  # async: false — these mutate LOOPYARD_HOME (a global) to isolate on-disk state.
  use ExUnit.Case, async: false

  alias Loopyard.Workstation

  setup do
    prev = System.get_env("LOOPYARD_HOME")
    tmp = Path.join(System.tmp_dir!(), "loopyard-test-#{System.unique_integer([:positive])}")
    System.put_env("LOOPYARD_HOME", tmp)

    on_exit(fn ->
      if prev, do: System.put_env("LOOPYARD_HOME", prev), else: System.delete_env("LOOPYARD_HOME")
      File.rm_rf(tmp)
    end)

    :ok
  end

  describe "valid_id?/1" do
    test "accepts lowercase, digits, dashes" do
      assert Workstation.valid_id?("brad")
      assert Workstation.valid_id?("brad-deploy")
      assert Workstation.valid_id?("jamie2")
    end

    test "rejects uppercase, spaces, leading dash, and non-binaries" do
      refute Workstation.valid_id?("Brad")
      refute Workstation.valid_id?("has space")
      refute Workstation.valid_id?("-leading")
      refute Workstation.valid_id?("")
      refute Workstation.valid_id?(nil)
    end
  end

  describe "create + list + current" do
    test "create makes the dir and list/exists? see it" do
      assert :ok = Workstation.create("brad")
      assert Workstation.exists?("brad")
      assert "brad" in Workstation.list()
    end

    test "create rejects invalid ids and duplicates" do
      assert {:error, :invalid_id} = Workstation.create("Nope Space")
      assert :ok = Workstation.create("dup")
      assert {:error, :exists} = Workstation.create("dup")
    end

    test "set_current switches the operating-as identity; bogus ids are rejected" do
      :ok = Workstation.create("brad")
      :ok = Workstation.create("jamie")

      assert :ok = Workstation.set_current("brad")
      assert Workstation.current() == "brad"
      assert :ok = Workstation.set_current("jamie")
      assert Workstation.current() == "jamie"

      assert {:error, :not_found} = Workstation.set_current("ghost")
      assert Workstation.current() == "jamie"
    end

    test "current bootstraps an identity when none exists (never empty)" do
      id = Workstation.current()
      assert Workstation.valid_id?(id)
      assert Workstation.exists?(id)
    end
  end

  describe "default_id/0" do
    test "is always a valid id and never the generic 'default'-with-spaces junk" do
      id = Workstation.default_id()
      assert Workstation.valid_id?(id)
    end
  end

  describe "ensure_context/1 (regression: the COPY loopyard-open build failure)" do
    test "create seeds the FULL build context, not just the Dockerfile" do
      :ok = Workstation.create("brad")
      dir = Workstation.dir("brad")

      assert File.exists?(Path.join(dir, "Dockerfile"))
      # The Dockerfile does `COPY loopyard-open ...`; the sibling must be present
      # or `docker build` fails with "loopyard-open: not found".
      assert File.exists?(Path.join(dir, "loopyard-open"))
    end

    test "fills missing sibling files but preserves an existing (edited) Dockerfile" do
      dir = Workstation.dir("edited")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Dockerfile"), "FROM debian:bookworm-slim\n# my edit\n")
      refute File.exists?(Path.join(dir, "loopyard-open"))

      :ok = Workstation.ensure_context("edited")

      assert File.exists?(Path.join(dir, "loopyard-open"))
      # Edit preserved — ensure_context only seeds the Dockerfile when ABSENT.
      assert File.read!(Path.join(dir, "Dockerfile")) =~ "# my edit"
    end
  end

  describe "naming (per identity)" do
    test "container / volume names are derived from the id" do
      # Prefixed per environment so the suite can't name (or clobber) the
      # developer's real container/volume — see resource_prefix/0.
      p = Workstation.resource_prefix()
      assert Workstation.container_name("brad") == "#{p}ws-brad"
      assert Workstation.home_volume("brad") == "#{p}ws-brad-home"
    end
  end

  describe "rename/2 (filesystem effects; Docker resources absent)" do
    @tag :docker
    test "moves the dir and follows .current" do
      :ok = Workstation.create("old")
      :ok = Workstation.set_current("old")

      assert :ok = Workstation.rename("old", "new")
      refute Workstation.exists?("old")
      assert Workstation.exists?("new")
      assert Workstation.current() == "new"
    end

    test "rejects renaming to an invalid or taken id" do
      :ok = Workstation.create("a")
      :ok = Workstation.create("b")
      assert {:error, :invalid_id} = Workstation.rename("a", "Bad Id")
      assert {:error, :exists} = Workstation.rename("a", "b")
      assert {:error, :not_found} = Workstation.rename("ghost", "x")
    end
  end
end
