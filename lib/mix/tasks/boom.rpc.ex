defmodule Mix.Tasks.Boom.Rpc do
  @moduledoc """
  Evaluate Elixir on the running BoomLooper node.

  ## Usage

      mix boom.rpc "BoomLooper.ChatAgent.list_agents()"
      mix boom.rpc "BoomLooper.ProjectRegistry.list_projects()"
      mix boom.rpc ":ets.tab2list(:project_registry)"
      mix boom.rpc "GenServer.call(pid, :state)"
      mix boom.rpc "BoomLooper.EvalRunner.run(path, clean: true)"

  Any valid Elixir expression. Result is inspected and printed.
  Reads the cookie from ~/.boomlooper/cookie automatically.
  """

  use Mix.Task

  @shortdoc "Evaluate Elixir on the running BoomLooper node"

  @impl Mix.Task
  def run(args) do
    expr = Enum.join(args, " ")

    if expr == "" do
      Mix.shell().info(@moduledoc)
      return()
    end

    {node, _cookie} = connect!()

    # Show operator indicator in the UI while jacked in
    :rpc.call(node, BoomLooper.IExSession, :working, ["rpc: #{String.slice(expr, 0, 60)}"])

    try do
      case :rpc.call(node, Code, :eval_string, [expr], 600_000) do
        {:badrpc, :nodedown} ->
          Mix.raise("BoomLooper node is down. Start with: mix boom.server")

        {:badrpc, reason} ->
          Mix.raise("RPC failed: #{inspect(reason)}")

        {value, _bindings} ->
          Mix.shell().info(inspect(value, pretty: true, limit: :infinity, printable_limit: :infinity))
      end
    after
      # Clear the indicator when done
      :rpc.call(node, BoomLooper.IExSession, :disconnect, [])
    end
  end

  defp return, do: :ok

  defp connect! do
    node = target_node()
    cookie = read_cookie()

    sname = :"rpc_#{System.pid()}_#{System.monotonic_time()}"
    case Node.start(sname, :shortnames) do
      {:ok, _} -> Node.set_cookie(cookie)
      {:error, reason} ->
        Mix.raise("Could not start distributed node: #{inspect(reason)}. Is epmd running?")
    end

    case :net_adm.ping(node) do
      :pong -> :ok
      :pang -> Mix.raise("BoomLooper node (#{node}) is not reachable. Start with: mix boom.server")
    end

    {node, cookie}
  end

  defp target_node do
    {:ok, hostname} = :inet.gethostname()
    :"boom@#{hostname}"
  end

  defp read_cookie do
    default_home = Path.join(System.user_home!(), ".boomlooper")
    env_home = System.get_env("BOOMLOOPER_HOME")

    # Try BOOMLOOPER_HOME first, fall back to ~/.boomlooper
    path = cond do
      env_home && File.exists?(Path.join(env_home, "cookie")) ->
        Path.join(env_home, "cookie")
      File.exists?(Path.join(default_home, "cookie")) ->
        Path.join(default_home, "cookie")
      true ->
        Mix.raise("Cookie not found. Checked #{if env_home, do: Path.join(env_home, "cookie") <> " and "}#{Path.join(default_home, "cookie")}. Is BoomLooper running?")
    end

    path |> File.read!() |> String.trim() |> String.to_atom()
  end
end
