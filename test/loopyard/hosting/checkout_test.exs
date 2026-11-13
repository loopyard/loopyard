defmodule Loopyard.Hosting.CheckoutTest do
  # git / mix / npm all go through a fake runner — no repo is touched.
  use ExUnit.Case, async: true

  alias Loopyard.Hosting.Checkout

  @moduletag :tmp_dir

  @old "1111111111111111111111111111111111111111"
  @new "2222222222222222222222222222222222222222"

  # `answers` maps {cmd, args-without-the-`-C dir`-prefix} to a result;
  # `HEAD` answers the old sha until a pull has run, then the new one.
  defp runner(answers) do
    test = self()
    pulled = :counters.new(1, [])

    fn cmd, args, opts ->
      args = strip_c(args)
      send(test, {:cmd, cmd, args, opts})

      case {cmd, args} do
        {"git", ["rev-parse", "HEAD"]} ->
          if :counters.get(pulled, 1) == 0,
            do: {@old <> "\n", 0},
            else: {answers[:head] || @new, 0}

        {"git", ["pull", "--ff-only"]} = key ->
          :counters.add(pulled, 1, 1)
          Map.get(answers, key, {"", 0})

        key ->
          Map.get(answers, key, {"", 0})
      end
    end
  end

  defp strip_c(["-C", _dir | rest]), do: rest
  defp strip_c(args), do: args

  defp calls do
    receive do
      {:cmd, cmd, args, opts} -> [{cmd, args, opts} | calls()]
    after
      0 -> []
    end
  end

  defp cmds, do: Enum.map(calls(), fn {c, a, _} -> {c, a} end)

  describe "update/2" do
    test "fast-forwards, prepares and reports the move", %{tmp_dir: tmp} do
      assert {:ok, {@old, @new}} = Checkout.update(tmp, runner: runner(%{}), mix: "/bin/mix")

      cmds = cmds()
      assert {"git", ["pull", "--ff-only"]} in cmds
      assert {"/bin/mix", ["deps.get"]} in cmds
      assert {"/bin/mix", ["compile"]} in cmds
      refute Enum.any?(cmds, &match?({"git", ["reset" | _]}, &1))
    end

    test "builds in the checkout's own dev build, not the caller's", %{tmp_dir: tmp} do
      {:ok, _} = Checkout.update(tmp, runner: runner(%{}), mix: "mix")

      {_, _, opts} = Enum.find(calls(), &match?({"mix", ["compile"], _}, &1))
      assert opts[:cd] == tmp
      assert {"MIX_ENV", "dev"} in opts[:env]
      assert {"MIX_BUILD_PATH", nil} in opts[:env]
    end

    test "nothing to pull → up to date, nothing built", %{tmp_dir: tmp} do
      assert {:ok, :up_to_date} = Checkout.update(tmp, runner: runner(%{head: @old}))
      refute Enum.any?(cmds(), &match?({"mix", _}, &1))
    end

    test "a compile failure puts the checkout back and says so", %{tmp_dir: tmp} do
      r = runner(%{{"mix", ["compile"]} => {"** (CompileError) lib/x.ex:1: oops", 1}})

      assert {:error, why} = Checkout.update(tmp, runner: r, mix: "mix")
      assert why =~ "does not build"
      assert why =~ "CompileError"
      assert why =~ "back on 11111111"
      assert {"git", ["reset", "--keep", @old]} in cmds()
    end

    test "refuses a checkout with uncommitted changes", %{tmp_dir: tmp} do
      r =
        runner(%{
          {"git", ["status", "--porcelain", "--untracked-files=no"]} => {" M lib/x.ex\n", 0}
        })

      assert {:error, why} = Checkout.update(tmp, runner: r)
      assert why =~ "uncommitted changes"
      refute Enum.any?(cmds(), &match?({"git", ["pull" | _]}, &1))
    end

    test "a non-fast-forward pull stops before anything is built", %{tmp_dir: tmp} do
      r =
        runner(%{{"git", ["pull", "--ff-only"]} => {"fatal: Not possible to fast-forward", 128}})

      assert {:error, why} = Checkout.update(tmp, runner: r)
      assert why =~ "Not possible to fast-forward"
      refute Enum.any?(cmds(), &match?({"mix", _}, &1))
    end

    test "reinstalls JS deps only when the lockfile moved", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "assets/node_modules"))
      lock_diff = {"git", ["diff", "--quiet", @old, @new, "--", "assets/package-lock.json"]}

      {:ok, _} = Checkout.update(tmp, runner: runner(%{lock_diff => {"", 0}}))
      refute Enum.any?(cmds(), &match?({"npm", _}, &1))

      {:ok, _} = Checkout.update(tmp, runner: runner(%{lock_diff => {"", 1}}))
      assert {"npm", ["ci", "--prefix", "assets"]} in cmds()
    end
  end

  describe "create/4" do
    test "clones locally, points origin upstream, then prepares", %{tmp_dir: tmp} do
      dest = Path.join(tmp, "server")
      r = runner(%{{"git", ["remote", "get-url", "origin"]} => {"git@github.com:o/r.git\n", 0}})

      assert :ok = Checkout.create("/src", dest, "main", runner: r, mix: "mix")

      assert [
               {"git", ["clone", "--branch", "main", "/src", ^dest]},
               {"git", ["remote", "get-url", "origin"]},
               {"git", ["remote", "set-url", "origin", "git@github.com:o/r.git"]},
               {"mix", ["deps.get"]},
               {"mix", ["compile"]}
             ] = cmds()
    end

    test "never clones over an existing directory", %{tmp_dir: tmp} do
      assert {:error, why} = Checkout.create("/src", tmp, "main", runner: runner(%{}))
      assert why =~ "already exists"
      assert cmds() == []
    end
  end
end
