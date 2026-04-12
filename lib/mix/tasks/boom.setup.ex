defmodule Mix.Tasks.Boom.Setup do
  @moduledoc """
  One-command setup for BoomLooper on a new machine.

  ## Usage

      mix boom.setup

  This will:
  1. Install Brewfile dependencies (elixir, node, fswatch, mutagen)
  2. Fix Docker credential store if misconfigured (colima users)
  3. Remove stale Docker Desktop buildx builders
  4. Install Hex + Rebar locally
  5. Fetch Mix dependencies
  6. Build assets

  Safe to re-run — each step is idempotent.
  """

  use Mix.Task

  @shortdoc "Set up BoomLooper (deps, Docker, assets)"

  @impl Mix.Task
  def run(_args) do
    info("Setting up BoomLooper...\n")

    step("Brewfile dependencies", fn -> brew_bundle() end)
    step("Docker credential store", fn -> fix_docker_creds() end)
    step("Docker buildx builders", fn -> clean_buildx() end)
    step("Hex + Rebar", fn -> hex_rebar() end)
    step("Mix dependencies", fn -> mix_deps() end)
    step("Assets", fn -> assets() end)

    info("\n✓ Setup complete. Run: mix boom.server\n")
  end

  defp step(name, fun) do
    info("  #{name}...")

    case fun.() do
      :ok -> info("  #{name} ✓")
      {:ok, msg} -> info("  #{name} ✓ #{msg}")
      {:skip, msg} -> info("  #{name} — #{msg}")
      {:error, msg} -> warn("  #{name} ✗ #{msg}")
    end
  end

  defp brew_bundle do
    if System.find_executable("brew") do
      {output, code} = System.cmd("brew", ["bundle", "install", "--no-lock"],
        cd: File.cwd!(), stderr_to_stdout: true)

      if code == 0, do: :ok, else: {:error, output}
    else
      {:skip, "brew not found (Linux? Install deps manually)"}
    end
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
    Mix.Task.run("local.hex", ["--force"])
    Mix.Task.run("local.rebar", ["--force"])
    :ok
  end

  defp mix_deps do
    Mix.Task.run("deps.get")
    :ok
  end

  defp assets do
    Mix.Task.run("assets.setup")
    Mix.Task.run("assets.build")
    :ok
  end

  defp info(msg), do: Mix.shell().info(msg)
  defp warn(msg), do: Mix.shell().info([:yellow, msg, :reset])
end
