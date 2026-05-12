defmodule Loopyard.MixProject do
  use Mix.Project

  def project do
    [
      app: :loopyard,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      mod: {Loopyard.Application, []},
      extra_applications: [:logger, :runtime_tools, :ssh, :crypto, :public_key]
    ]
  end

  def cli do
    [preferred_envs: [coveralls: :test, "coveralls.detail": :test, "coveralls.html": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.20"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:phoenix_live_view, "~> 1.0"},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.6"},
      {:claude_code, "~> 0.34"},
      {:dotenvy, "~> 0.9"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:eqrcode, "~> 0.1.10"},
      {:yaml_elixir, "~> 2.9"},
      {:makeup, "~> 1.2"},
      {:makeup_syntect, "~> 0.1"},

      # Quality tools
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      # Force a full `mix compile` BEFORE test file compilation kicks
      # in. Elixir 1.19's parallel compiler can resolve a test file's
      # `%Events.X.Y{}` struct reference before the lib module that
      # defines it has finished compiling — flaky "is not loaded and
      # could not be found" errors on clean builds. Serializing the
      # lib compile first costs a second or two and makes the suite
      # deterministic.
      test: ["compile", "test"],
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind loopyard", "esbuild loopyard"],
      "assets.deploy": [
        "tailwind loopyard --minify",
        "esbuild loopyard --minify",
        "phx.digest"
      ]
    ]
  end
end
