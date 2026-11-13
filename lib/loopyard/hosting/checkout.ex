defmodule Loopyard.Hosting.Checkout do
  @moduledoc """
  The service's DEDICATED checkout — a clone that moves only on a deliberate
  `mix loopyard.service update`.

  ## Why the service should not run from your working tree

  The server runs in dev mode with the code reloader on: every request
  recompiles whatever changed in the checkout it runs from. An edit there that
  does not compile — yours, or an agent's mid-change — freezes every page of
  the always-on server until it is fixed. A separate checkout keeps the
  server on code that compiled, and `update/2` only moves it forward after the
  new code compiles; when it does not, the checkout is put back where it was
  and the running server is left alone.

  All git / mix / npm calls go through the injectable `:runner`
  (`System.cmd/3` shape), so tests drive these flows without touching a repo.
  """

  @doc """
  Clone `source` (a local checkout) into `dest` on `branch`, point its
  `origin` at `source`'s own `origin` (so updates come from upstream, not from
  your working tree) and prepare it to run. A local clone is fast and needs no
  credentials.
  """
  @spec create(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def create(source, dest, branch, opts \\ []) do
    runner = Loopyard.Hosting.runner(opts)

    if File.exists?(dest) do
      {:error, "#{dest} already exists"}
    else
      with :ok <- step(runner, "git", ["clone", "--branch", branch, source, dest], []),
           :ok <- set_upstream(runner, source, dest) do
        prepare(dest, opts)
      end
    end
  end

  defp set_upstream(runner, source, dest) do
    case runner.("git", ["-C", source, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {url, 0} ->
        step(runner, "git", ["-C", dest, "remote", "set-url", "origin", String.trim(url)], [])

      # No upstream: the clone keeps pointing at `source`, which still works.
      _ ->
        :ok
    end
  end

  @doc """
  Make `checkout` runnable: fetch Mix deps, install the JS deps the asset
  build needs when they are missing (or `npm: true`), and compile. Run in a
  clean environment (`MIX_ENV=dev`, no inherited `MIX_BUILD_PATH`) so it
  builds into the checkout's own `_build/dev` — what the service boots from.
  """
  @spec prepare(String.t(), keyword()) :: :ok | {:error, String.t()}
  def prepare(checkout, opts \\ []) do
    runner = Loopyard.Hosting.runner(opts)
    mix = Keyword.get(opts, :mix, "mix")
    env = [{"MIX_ENV", "dev"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}, {"MIX_EXS", nil}]
    cmd_opts = [cd: checkout, env: env]

    npm? =
      Keyword.get(opts, :npm, false) or
        (File.regular?(Path.join([checkout, "assets", "package.json"])) and
           not File.dir?(Path.join([checkout, "assets", "node_modules"])))

    with :ok <- step(runner, mix, ["deps.get"], cmd_opts),
         :ok <-
           if(npm?, do: step(runner, "npm", ["ci", "--prefix", "assets"], cmd_opts), else: :ok) do
      step(runner, mix, ["compile"], cmd_opts)
    end
  end

  @type update_result ::
          {:ok, :up_to_date} | {:ok, {String.t(), String.t()}} | {:error, String.t()}

  @doc """
  Fast-forward `checkout` from its upstream and compile it. Returns
  `{:ok, {old_sha, new_sha}}` when it moved and compiled (the caller then
  restarts the service), `{:ok, :up_to_date}` when there was nothing to pull,
  or `{:error, why}` — after a failed compile the checkout is reset to
  `old_sha` (`git reset --keep`, which never discards local changes) so the
  running server keeps serving code that builds.

  Refuses a checkout with uncommitted changes: a dedicated checkout should
  have none, and a fast-forward over them is exactly the hazard it exists to
  avoid.
  """
  @spec update(String.t(), keyword()) :: update_result()
  def update(checkout, opts \\ []) do
    runner = Loopyard.Hosting.runner(opts)
    git = fn args -> runner.("git", ["-C", checkout | args], stderr_to_stdout: true) end

    with {:clean, {"", 0}} <- {:clean, git.(["status", "--porcelain", "--untracked-files=no"])},
         {old, 0} <- git.(["rev-parse", "HEAD"]),
         :ok <- ok(git.(["pull", "--ff-only"]), "git pull --ff-only"),
         {new, 0} <- git.(["rev-parse", "HEAD"]) do
      old = String.trim(old)
      new = String.trim(new)

      if old == new do
        {:ok, :up_to_date}
      else
        npm? = lockfile_changed?(git, old, new)

        case prepare(checkout, Keyword.put(opts, :npm, npm?)) do
          :ok ->
            {:ok, {old, new}}

          {:error, why} ->
            _ = git.(["reset", "--keep", old])

            {:error,
             "the new code does not build: #{why}. The checkout is back on #{short(old)} " <>
               "and the running server was left alone."}
        end
      end
    else
      {:clean, {out, 0}} ->
        {:error,
         "#{checkout} has uncommitted changes:\n#{out}\nA service checkout should only " <>
           "move on update; commit or discard them there first."}

      {:clean, {out, status}} ->
        {:error, "git status failed (exit #{status}): #{String.trim(out)}"}

      {:error, _} = err ->
        err

      {out, status} ->
        {:error, "git failed (exit #{status}): #{String.trim(out)}"}
    end
  end

  defp lockfile_changed?(git, old, new) do
    match?({_, 1}, git.(["diff", "--quiet", old, new, "--", "assets/package-lock.json"]))
  end

  defp short(sha), do: String.slice(sha, 0, 8)

  defp step(runner, cmd, args, opts) do
    ok(
      runner.(cmd, args, Keyword.put(opts, :stderr_to_stdout, true)),
      Enum.join([cmd | args], " ")
    )
  end

  defp ok({_out, 0}, _what), do: :ok

  defp ok({out, status}, what) do
    tail = out |> String.split("\n") |> Enum.take(-20) |> Enum.join("\n") |> String.trim()
    {:error, "`#{what}` failed (exit #{status}):\n#{tail}"}
  end
end
