defmodule BoomLooper.MixProject do
  use Mix.Project

  def project do
    [
      app: :boom_looper,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {BoomLooper.Application, []},
      extra_applications: [:logger, :runtime_tools, :ssh, :crypto, :public_key]
    ]
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
      {:yaml_elixir, "~> 2.9"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind boom_looper", "esbuild boom_looper"],
      "assets.deploy": [
        "tailwind boom_looper --minify",
        "esbuild boom_looper --minify",
        "phx.digest"
      ]
    ]
  end
end
