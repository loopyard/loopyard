defmodule Loopyard.Workstation.EnvTest do
  use ExUnit.Case, async: false

  alias Loopyard.Workstation
  alias Loopyard.Workstation.Env

  # A unique identity per test so the LOOPYARD_HOME store (test_helper points it
  # at a local dir) never collides with another test or a real workstation.
  setup do
    id = "envtest_#{:erlang.unique_integer([:positive])}"
    path = Path.join(Workstation.dir(id), "env.json")
    File.mkdir_p!(Path.dirname(path))
    on_exit(fn -> File.rm_rf!(Workstation.dir(id)) end)
    %{id: id, path: path}
  end

  defp write_store(path, map), do: File.write!(path, Jason.encode!(map))

  describe "read_map/1 — the three-way outcome that prevents clobbering" do
    test "genuinely absent store → :absent (empty is a valid start)", %{id: id, path: path} do
      File.rm_rf!(path)
      assert Env.read_map(id) == :absent
    end

    test "valid store → {:ok, map}", %{id: id, path: path} do
      write_store(path, %{"A" => "1", "B" => "2"})
      assert Env.read_map(id) == {:ok, %{"A" => "1", "B" => "2"}}
    end

    test "corrupt/truncated store → {:error, _}, NOT empty", %{id: id, path: path} do
      # This is the exact failure that decayed the identity store to one key:
      # a half-written file. read_map must report an error, not pretend it's {}.
      File.write!(path, "{\"A\": \"1\", \"B\":")
      assert {:error, _} = Env.read_map(id)
    end

    test "non-object JSON → {:error, :not_a_map}", %{id: id, path: path} do
      File.write!(path, "[1,2,3]")
      assert {:error, :not_a_map} = Env.read_map(id)
    end
  end

  describe "current_for_write/1 — writers never merge onto an assumed-empty store" do
    test "absent → {:ok, %{}} (fresh store starts empty)", %{id: id, path: path} do
      File.rm_rf!(path)
      assert Env.current_for_write(id) == {:ok, %{}}
    end

    test "valid → {:ok, map} with every key preserved", %{id: id, path: path} do
      write_store(path, %{"CLAUDE_CODE_OAUTH_TOKEN" => "x", "GITHUB_TOKEN" => "y"})

      assert {:ok, %{"CLAUDE_CODE_OAUTH_TOKEN" => "x", "GITHUB_TOKEN" => "y"}} =
               Env.current_for_write(id)
    end

    test "corrupt → {:error, {:store_unreadable, _}} so a put REFUSES rather than clobbers",
         %{id: id, path: path} do
      File.write!(path, "not json at all")
      assert {:error, {:store_unreadable, _}} = Env.current_for_write(id)
    end
  end

  describe "all/1 stays lenient for read paths" do
    test "missing or corrupt → %{} (readers tolerate; only WRITERS refuse)", %{
      id: id,
      path: path
    } do
      File.rm_rf!(path)
      assert Env.all(id) == %{}
      File.write!(path, "garbage")
      assert Env.all(id) == %{}
    end
  end

  describe "credential writes announce themselves" do
    test "put/3 broadcasts so an open integration page re-probes", %{id: id} do
      Loopyard.Events.Workstation.subscribe(id)

      assert :ok = Env.put("FLY_ACCESS_TOKEN", "tok-123", id)

      assert_receive %Loopyard.Events.Workstation.CredentialsChanged{
        workstation_id: ^id,
        source: :env,
        key: "FLY_ACCESS_TOKEN"
      }
    end

    test "delete/2 broadcasts too — disconnecting is also a state change", %{id: id} do
      :ok = Env.put("FLY_ACCESS_TOKEN", "tok-123", id)
      Loopyard.Events.Workstation.subscribe(id)

      Env.delete("FLY_ACCESS_TOKEN", id)

      assert_receive %Loopyard.Events.Workstation.CredentialsChanged{
        workstation_id: ^id,
        source: :env,
        key: "FLY_ACCESS_TOKEN"
      }
    end
  end
end
