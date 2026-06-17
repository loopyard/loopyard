defmodule Mix.Tasks.Loopyard.Rpc do
  @moduledoc """
  Evaluate Elixir on the running Loopyard node.

  ## Usage

      mix loopyard.rpc "Loopyard.ChatAgent.list_agents()"
      mix loopyard.rpc "Loopyard.ProjectRegistry.list_projects()"
      mix loopyard.rpc ":ets.tab2list(:project_registry)"
      mix loopyard.rpc "GenServer.call(pid, :state)"
      mix loopyard.rpc "Loopyard.EvalRunner.run(path, clean: true)"

  Any valid Elixir expression. Result is inspected and printed.
  Reads the cookie from ~/.loopyard/cookie automatically.
  """

  use Mix.Task

  @shortdoc "Evaluate Elixir on the running Loopyard node"

  @impl Mix.Task
  def run(args) do
    expr = Enum.join(args, " ")

    if expr == "" do
      Mix.shell().info(@moduledoc)
      return()
    end

    {node, _cookie} = connect!()

    # Show operator indicator in the UI while jacked in
    :rpc.call(node, Loopyard.IExSession, :working, ["rpc: #{String.slice(expr, 0, 60)}"])

    try do
      case :rpc.call(node, Code, :eval_string, [expr], 600_000) do
        {:badrpc, :nodedown} ->
          Mix.raise("Loopyard node is down. Start with: mix loopyard.server")

        {:badrpc, reason} ->
          Mix.raise("RPC failed: #{inspect(reason)}")

        {value, _bindings} ->
          Mix.shell().info(
            inspect(value, pretty: true, limit: :infinity, printable_limit: :infinity)
          )
      end
    after
      # Only disconnect if the command didn't claim the session.
      # Long-running tasks (like EvalRunner) claim the session and disconnect themselves when done.
      :rpc.call(node, Loopyard.IExSession, :disconnect_unless_claimed, [])
    end
  end

  defp return, do: :ok

  defp connect! do
    node = target_node()
    cookie = read_cookie()

    sname = :"rpc_#{System.pid()}_#{System.monotonic_time()}@127.0.0.1"

    case Node.start(sname, :longnames) do
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

  defp target_node do
    # Pin to a loopback longname so remote access survives macOS hostname flips
    # (Mac ↔ Mac.localdomain ↔ macbook), which silently broke `loopyard.rpc`.
    :"loopyard@127.0.0.1"
  end

  defp read_cookie do
    # Always use ~/.loopyard/cookie — matches loopyard.server
    path = Path.join([System.user_home!(), ".loopyard", "cookie"])

    unless File.exists?(path) do
      Mix.raise("Cookie not found at #{path}. Is Loopyard running?")
    end

    path |> File.read!() |> String.trim() |> String.to_atom()
  end
end
