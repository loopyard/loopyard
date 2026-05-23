defmodule Aural.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :aural,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: ["lib"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Cerebral ambient audio bed for Phoenix apps. Synth + ffmpeg fan-out via PubSub, drop-in LiveView page, instant chimes.",
      package: [
        licenses: ["AGPL-3.0-or-later"],
        links: %{"GitHub" => "https://github.com/bradgessler/loopyard"}
      ]
    ]
  end

  def application do
    [
      mod: {Aural.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.2"},
      {:plug, "~> 1.14"}
    ]
  end
end
