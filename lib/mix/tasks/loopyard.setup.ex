defmodule Mix.Tasks.Loopyard.Setup do
  @moduledoc """
  One-command setup for Loopyard on a new machine.

  ## Usage

      mix loopyard.setup

  This will:
  1. Install Brewfile dependencies (elixir, node, fswatch, mutagen)
  2. Fix Docker credential store if misconfigured (colima users)
  3. Remove stale Docker Desktop buildx builders
  4. Install Hex + Rebar locally
  5. Fetch Mix dependencies
  6. Install JavaScript dependencies and build assets
  7. Build the stock workspace base image

  Safe to re-run — each step is idempotent.
  """

  use Mix.Task

  @shortdoc "Set up Loopyard (deps, Docker, assets)"

  @impl Mix.Task
  def run(_args) do
    info("Setting up Loopyard...\n")

    step("Brewfile dependencies", fn -> brew_bundle() end)
    step("Docker Compose available", fn -> check_compose() end)
    step("Docker credential store", fn -> fix_docker_creds() end)
    step("Docker buildx builders", fn -> clean_buildx() end)
    step("Hex + Rebar", fn -> hex_rebar() end)
    step("Mix dependencies", fn -> mix_deps() end)
    step("Assets", fn -> assets() end)
    step("Workspace base image", fn -> workspace_image() end)

    info("\n✓ Setup complete. Run: mix loopyard.server\n")
  end

  defp step(name, fun) do
    info("  #{name}...")

    case fun.() do
      :ok -> info("  #{name} ✓")
      {:ok, msg} -> info("  #{name} ✓ #{msg}")
      {:skip, msg} -> info("  #{name} — #{msg}")
      {:error, msg} -> Mix.raise("#{name} failed: #{msg}")
    end
  end

  defp brew_bundle do
    if System.find_executable("brew") do
      with :ok <- run_command("brew", ["tap", "mutagen-io/mutagen"]),
           :ok <- trust_mutagen_formula(),
           :ok <- run_command("brew", ["bundle", "install"]) do
        :ok
      end
    else
      {:skip, "brew not found (Linux? Install deps manually)"}
    end
  end

  defp trust_mutagen_formula do
    case System.cmd("brew", ["command", "trust"], stderr_to_stdout: true) do
      {_, 0} -> run_command("brew", ["trust", "--formula", "mutagen-io/mutagen/mutagen"])
      _ -> :ok
    end
  end

  # Loopyard runs project stacks with Docker Compose. `cask "docker"` ships
  # the v2 plugin, but the README also documents Colima / OrbStack / Docker
  # Engine, where compose is a separate install. Warn at setup time rather
  # than letting the first project boot crash — see Compose.docker_compose/2.
  defp check_compose do
    v2? =
      match?({_, 0}, safe_cmd("docker", ["compose", "version"]))

    legacy? = System.find_executable("docker-compose") != nil

    cond do
      v2? ->
        {:ok, "docker compose (v2 plugin)"}

      legacy? ->
        {:ok, "docker-compose (standalone)"}

      true ->
        {:skip,
         "no Docker Compose found — install the compose plugin or docker-compose before running projects"}
    end
  end

  # Like System.cmd but never raises on a missing binary (returns a
  # non-zero-shaped result instead), so a probe can't crash setup.
  defp safe_cmd(exe, args) do
    if System.find_executable(exe) do
      System.cmd(exe, args, stderr_to_stdout: true)
    else
      {"", 127}
    end
  rescue
    _ -> {"", 127}
  end

  defp fix_docker_creds do
    config_path = Path.join(System.user_home!(), ".docker/config.json")

    with {:ok, json} <- File.read(config_path),
         {:ok, config} <- Jason.decode(json),
         "desktop" <- config["credsStore"] do
      # Check if desktop credential helper actually works
      case System.cmd("docker-credential-desktop", ["list"], stderr_to_stdout: true) do
        {_, 0} ->
          {:skip, "credsStore=desktop and it works"}

        _ ->
          # Fix it
          config = Map.put(config, "credsStore", "osxkeychain")
          File.write!(config_path, Jason.encode!(config, pretty: true))
          {:ok, "switched credsStore from desktop to osxkeychain"}
      end
    else
      {:error, :enoent} -> {:skip, "no ~/.docker/config.json"}
      _ -> :ok
    end
  end

  defp clean_buildx do
    removed =
      for builder <- ["default", "desktop-linux"] do
        case System.cmd("docker", ["buildx", "rm", builder], stderr_to_stdout: true) do
          {_, 0} -> builder
          _ -> nil
        end
      end
      |> Enum.reject(&is_nil/1)

    if removed == [] do
      {:skip, "no stale builders"}
    else
      {:ok, "removed: #{Enum.join(removed, ", ")}"}
    end
  end

  defp hex_rebar do
    with :ok <- run_command("mix", ["local.hex", "--force"]),
         :ok <- run_command("mix", ["local.rebar", "--force"]) do
      :ok
    end
  end

  defp mix_deps, do: run_command("mix", ["deps.get"])

  # Without the base image the FIRST agent on a fresh machine always fails:
  # the boot saga races ahead to `docker exec` the work container while
  # ensure_image/0 is still building it, surfacing as an opaque
  # {:harness_start_failed, {:closed, {:exit_status, 1}}}. Build it here so
  # that never happens. Idempotent — ensure_image/0 no-ops when present.
  defp workspace_image do
    Mix.Task.run("app.config")

    case Loopyard.Workspace.WorkContainer.ensure_image() do
      :ok ->
        {:ok, Loopyard.Workspace.WorkContainer.image()}

      # Never fail setup on this — Docker may legitimately not be running yet,
      # and ensure_image/0 retries lazily on first agent boot.
      {:error, reason} ->
        {:skip, "not built (#{inspect(reason)}) — will build on first agent"}
    end
  end

  defp assets do
    with :ok <- run_command("npm", ["ci", "--prefix", "assets"]),
         :ok <- run_command("mix", ["assets.setup"]),
         :ok <- run_command("mix", ["assets.build"]) do
      :ok
    end
  end

  defp run_command(executable, args) do
    if System.find_executable(executable) do
      case System.cmd(executable, args, cd: File.cwd!(), stderr_to_stdout: true) do
        {_, 0} -> :ok
        {output, _code} -> {:error, String.trim(output)}
      end
    else
      # On Linux, brew_bundle skips and nothing installs node — a missing
      # `npm` otherwise surfaced as a raw `** (ErlangError) :enoent`.
      {:error, "`#{executable}` not found on PATH — install it and re-run setup."}
    end
  end

  defp info(msg), do: Mix.shell().info(msg)
end
