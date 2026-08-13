defmodule LoopyardWeb.ShowcaseTest do
  @moduledoc """
  The showcase scenes are FEATURE-VIEW CONTRACTS, not just marketing props.
  Each scene renders a real surface (chat, full workspace cockpit, service
  logs, console, operator) from pure mock assigns — so this test breaks the
  build when a view starts reading global state in render, when a runtime
  data shape drifts away from what the views consume, or when load-bearing
  UI (the Stop button, the port link, the question card's commit action)
  silently disappears.

  Each scene module's `description/0` is the human/AI-facing spec of what the
  view shows; the markers below pin the load-bearing content. When you change
  a view on purpose, update the marker + the scene description together —
  they are the one place that says what this surface is FOR. Screenshots are
  generated from these same scenes via `mix loopyard.shot` (see the
  showcase-shots skill); this test is the serverless render of exactly that
  pipeline, so green here means the marketing shots still generate.
  """
  use ExUnit.Case, async: true

  alias LoopyardWeb.Showcase

  # scene name => content that MUST be present in the rendered page.
  @markers %{
    # An agent mid-turn: prompt band, tool timeline, live thinking, Stop.
    "chat-working" => [
      "Customers say the cart total flickers",
      "bin/rails test test/system/cart_test.rb",
      "The stepper is two",
      "Stop"
    ],
    # The ask_user card: options, per-question commit, needs-you framing.
    "question-card" => [
      "Where should staging deploys go?",
      "Fly.io (Recommended)",
      "Answer",
      "Skip"
    ],
    # First run: the on-ramp shown before any project exists — brand mark,
    # headline, and the three creation paths as one-tap rows (not a dead end).
    "workspaces-empty" => [
      "Start your first project",
      "From GitHub",
      "From scratch",
      "From a folder on the Loopyard machine"
    ],
    # The whole cockpit: tree with ports, chat, agents/services/usage rail.
    "workspace-full" => [
      "gardenparty",
      ":4007",
      "postgres",
      "Total tokens",
      "Restart agent"
    ],
    # Cockpit + a pending question card.
    "workspace-question" => [
      "Where should staging deploys go?",
      "Restart agent",
      "storefront"
    ],
    # Service log view: run boundaries survive crashes, port in the header.
    "dev-server" => [
      "Booting Puma",
      "STRIPE_KEY",
      "Completed",
      "Run"
    ],
    # Several agents on one workspace, each with its own live status.
    "multi-agent" => [
      "Test runner",
      "Running the suite",
      "Reviewer"
    ],
    # Browser terminal + the SSH path to the same session.
    "ssh-console" => [
      "bin/rails console",
      "SSH",
      "console"
    ],
    # The operator: overview + dispatch chat, For-You rail with running work.
    "operator" => [
      "Where do we stand?",
      "Dispatched to",
      "In motion",
      "Workstations"
    ],
    # The Reviewer deck: pending decisions one per slide, waiting count,
    # per-decision permalink, and a settled receipt staying traversable.
    "reviewer" => [
      "2 waiting",
      "Where should staging deploys go?",
      "Ship the fix now or hold for a real repro?",
      "Open this decision",
      "Answered"
    ],
    # The ambient sound bed's control page (the aural package's UI).
    "aural" => [
      "Ambient bed",
      "Serene",
      "Nocturne",
      "Volume"
    ]
  }

  test "every scene has a marker contract (add one when you add a scene)" do
    for scene <- Showcase.scenes() do
      assert Map.has_key?(@markers, scene.name()),
             "scene #{scene.name()} has no marker contract in #{__ENV__.file}"

      assert scene.description() != "", "scene #{scene.name()} needs a description"
    end
  end

  for scene <- LoopyardWeb.Showcase.scenes() do
    @scene scene
    test "scene #{scene.name()} renders with its load-bearing content" do
      html = Showcase.page_html(@scene)

      for marker <- Map.fetch!(@markers, @scene.name()) do
        assert html =~ marker,
               "scene #{@scene.name()} lost expected content #{inspect(marker)}"
      end
    end

    test "scene #{scene.name()} renders a dark variant" do
      dark = Showcase.page_html(@scene, :dark)

      # The theme pin rewrites the color-scheme query; if this stops matching,
      # dark screenshots silently come out light.
      refute dark =~ "@media (prefers-color-scheme: dark)"
      assert dark =~ "@media all"
    end
  end
end
