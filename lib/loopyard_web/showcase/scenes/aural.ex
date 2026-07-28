defmodule LoopyardWeb.Showcase.Scenes.Aural do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "aural",
    description:
      "The ambient sound bed's full-page control: power, volume, and the " <>
        "track roster (synthesized live by the aural package; agent activity " <>
        "drives the intensity)"

  @impl true
  def component, do: &LoopyardWeb.SoundLive.render/1

  @impl true
  def assigns do
    %{
      tracks: [
        {:serene, "Serene", "warm major-7 pads, slow breath rhythm"},
        {:nocturne, "Nocturne", "dark minor, deep bass, unhurried"},
        {:cascade, "Cascade", "rotating chord, gentle upward motion"},
        {:hum, "Hum", "brown-noise floor + sub-bass drone"},
        {:pink, "Pink", "1/f noise — a masker and sleep aid"}
      ],
      current_track: :serene
    }
  end
end
