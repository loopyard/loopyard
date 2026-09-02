defmodule Mix.Tasks.Loopyard.HarnessCheck do
  # Node names and the distribution cookie MUST be atoms (that's the API);
  # both come from this machine's own files/pid, not from a request.
  # credo:disable-for-this-file Credo.Check.Warning.UnsafeToAtom
  @moduledoc """
  Validate that Loopyard can actually drive a frontier harness end to end.

  Connects to the running Loopyard node and runs `Loopyard.HarnessCheck.probe/1`,
  which spawns a real harness session (Claude Code by default), streams one probe
  prompt, and confirms the expected token comes back through the neutral
  `Loopyard.Agent.Event` stream. Prints a PASS/FAIL report with latency and exits
  0 (pass) or 1 (fail) so it's loopable from a shell.

  ## Usage

      mix loopyard.harness_check                 # probe the default harness once
      mix loopyard.harness_check --loops 5       # probe N times, fail if any fail
      mix loopyard.harness_check --full <agent>  # full ChatAgent path against a live agent

  Reads the cookie from ~/.loopyard/cookie automatically.
  """

  use Mix.Task

  @shortdoc "Probe the harness round-trip on the running Loopyard node"

  @switches [loops: :integer, full: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches)
    loops = Keyword.get(opts, :loops, 1)
    full_agent = Keyword.get(opts, :full)

    {node, _cookie} = connect!()

    results =
      Enum.map(1..loops, fn i ->
        result = call_probe(node, full_agent)
        report(i, loops, result)
        result
      end)

    passed = Enum.count(results, &match?({:ok, _}, &1))
    failed = loops - passed

    Mix.shell().info("")

    Mix.shell().info(
      "#{passed}/#{loops} passed" <> if(failed > 0, do: ", #{failed} FAILED", else: "")
    )

    if failed > 0, do: exit({:shutdown, 1})
  end

  defp call_probe(node, nil) do
    case :rpc.call(node, Loopyard.HarnessCheck, :probe, [], 120_000) do
      {:badrpc, reason} -> {:error, %{reason: :rpc_failed, detail: reason}}
      other -> other
    end
  end

  defp call_probe(node, agent_id) do
    case :rpc.call(node, Loopyard.HarnessCheck, :agent_turn, [agent_id], 120_000) do
      {:badrpc, reason} -> {:error, %{reason: :rpc_failed, detail: reason}}
      other -> other
    end
  end

  defp report(i, loops, {:ok, info}) do
    Mix.shell().info(
      "[#{i}/#{loops}] ✓ PASS  #{info.latency_ms}ms  #{inspect(info[:backend] || :agent)}  → #{String.slice(info.response, 0, 40)}"
    )
  end

  defp report(i, loops, {:error, info}) do
    Mix.shell().error("[#{i}/#{loops}] ✗ FAIL  #{inspect(info, pretty: true)}")
  end

  # --- node connection (mirrors Mix.Tasks.Loopyard.Rpc) ---

  defp connect! do
    node = :"loopyard@127.0.0.1"
    cookie = read_cookie()

    sname = :"harness_check_#{System.pid()}_#{System.monotonic_time()}@127.0.0.1"

    case Node.start(sname, name_domain: :longnames) do
      {:ok, _} ->
        Node.set_cookie(cookie)

      {:error, reason} ->
        Mix.raise("Could not start distributed node: #{inspect(reason)}. Is epmd running?")
    end

    case :net_adm.ping(node) do
      :pong ->
        :ok

      :pang ->
        Mix.raise("Loopyard node (#{node}) is not reachable. Start with: mix loopyard.server")
    end

    {node, cookie}
  end

  defp read_cookie do
    path = Path.join([System.user_home!(), ".loopyard", "cookie"])

    unless File.exists?(path) do
      Mix.raise("Cookie not found at #{path}. Is Loopyard running?")
    end

    path |> File.read!() |> String.trim() |> String.to_atom()
  end
end
