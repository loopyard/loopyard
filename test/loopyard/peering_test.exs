defmodule Loopyard.PeeringTest do
  use ExUnit.Case

  alias Loopyard.Peering

  # The store file (<LOOPYARD_HOME>/peering.json) is shared across tests,
  # so every test uses unique workspace ids and revokes its own grants.

  defp unique_ws(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp cleanup_pair(ws_a, ws_b) do
    on_exit(fn ->
      Peering.revoke(ws_a, ws_b)
      Peering.revoke(ws_b, ws_a)
    end)
  end

  describe "grant_pair/2" do
    test "writes BOTH directions" do
      ws_a = unique_ws("pair-a")
      ws_b = unique_ws("pair-b")
      cleanup_pair(ws_a, ws_b)

      assert :ok = Peering.grant_pair(ws_a, ws_b)

      assert Peering.granted?(ws_a, ws_b)
      assert Peering.granted?(ws_b, ws_a)
    end

    test "is idempotent — granting twice leaves exactly one entry per direction" do
      ws_a = unique_ws("idem-a")
      ws_b = unique_ws("idem-b")
      cleanup_pair(ws_a, ws_b)

      assert :ok = Peering.grant_pair(ws_a, ws_b)
      assert :ok = Peering.grant_pair(ws_a, ws_b)

      ours =
        Enum.filter(Peering.load(), fn g ->
          g["from"] in [ws_a, ws_b] or g["to"] in [ws_a, ws_b]
        end)

      assert length(ours) == 2
      assert %{"from" => ws_a, "to" => ws_b} in ours
      assert %{"from" => ws_b, "to" => ws_a} in ours
    end
  end

  describe "granted?/2" do
    test "is directional — a revoked direction is not granted while the other still is" do
      ws_a = unique_ws("dir-a")
      ws_b = unique_ws("dir-b")
      cleanup_pair(ws_a, ws_b)

      Peering.grant_pair(ws_a, ws_b)
      Peering.revoke(ws_a, ws_b)

      refute Peering.granted?(ws_a, ws_b)
      assert Peering.granted?(ws_b, ws_a)
    end

    test "is false for workspaces that were never granted" do
      refute Peering.granted?(unique_ws("never-a"), unique_ws("never-b"))
    end
  end

  describe "peers_of/1" do
    test "lists only targets where from == ws" do
      ws_a = unique_ws("peers-a")
      ws_b = unique_ws("peers-b")
      ws_c = unique_ws("peers-c")
      cleanup_pair(ws_a, ws_b)
      cleanup_pair(ws_a, ws_c)

      Peering.grant_pair(ws_a, ws_b)
      Peering.grant_pair(ws_a, ws_c)
      # Make b→a one-way only: b may no longer send to a.
      Peering.revoke(ws_b, ws_a)

      peers_a = Peering.peers_of(ws_a)
      assert ws_b in peers_a
      assert ws_c in peers_a

      # b has no outgoing grants left — a's a→b grant must not show up.
      refute ws_a in Peering.peers_of(ws_b)
    end

    test "is empty for an unknown workspace" do
      assert Peering.peers_of(unique_ws("peers-none")) == []
    end
  end

  describe "revoke/2" do
    test "removes one direction only" do
      ws_a = unique_ws("rev-a")
      ws_b = unique_ws("rev-b")
      cleanup_pair(ws_a, ws_b)

      Peering.grant_pair(ws_a, ws_b)
      assert :ok = Peering.revoke(ws_a, ws_b)

      refute Peering.granted?(ws_a, ws_b)
      assert Peering.granted?(ws_b, ws_a)
    end
  end

  describe "corrupt store file" do
    test "load/0 returns [] and granted? is false (fail-closed)" do
      path = Peering.path()
      original = File.read(path)

      on_exit(fn ->
        case original do
          {:ok, content} -> File.write!(path, content)
          _ -> File.rm(path)
        end
      end)

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "this is {{{ not json")

      assert Peering.load() == []
      refute Peering.granted?(unique_ws("corrupt-a"), unique_ws("corrupt-b"))
    end
  end
end
