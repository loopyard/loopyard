defmodule Brand.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :brand,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: ["lib"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "The Loopyard brand as code: the trefoil mark + motion, color tokens " <>
          "(Tailwind preset), and usage rules — the ONE source of truth shared " <>
          "by the app and the marketing site (loopyard.ai).",
      package: [
        licenses: ["AGPL-3.0-or-later"],
        links: %{"GitHub" => "https://github.com/loopyard/loopyard"}
      ]
    ]
  end

  def application, do: [extra_applications: []]

  defp deps do
    [
      {:phoenix_live_view, "~> 1.0"}
    ]
  end
end
