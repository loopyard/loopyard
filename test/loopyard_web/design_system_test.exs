defmodule LoopyardWeb.DesignSystemTest do
  @moduledoc """
  STATIC GUARDRAILS for the design system — greps over the web layer that fail
  the build when an architecture rule regresses. Each assertion encodes a rule
  that was violated once and cost a debugging session; see docs/CODE_RULES.md
  ("Design system") for the why behind each.
  """
  use ExUnit.Case, async: true

  @web_root "lib/loopyard_web"

  defp web_sources do
    Path.wildcard("#{@web_root}/**/*.{ex,heex}")
    |> Enum.map(&{&1, File.read!(&1)})
  end

  test "sharp editorial: no large corner radii in the web layer" do
    # Surfaces are square; controls are rounded-sm; circles are rounded-full.
    # (The rounding apparatus — grouped-corner logic, sticky corner-squaring —
    # was deleted deliberately; large radii coming back means it's drifting in.)
    offenders =
      for {path, src} <- web_sources(),
          Regex.match?(~r/\brounded-(?:t-|b-|tl-|tr-|bl-|br-)?(?:md|lg|xl|2xl|3xl)\b/, src),
          do: path

    assert offenders == [],
           "large radii found (use rounded-sm / rounded-full per the sharp-editorial rule): #{inspect(offenders)}"
  end

  test "accent: the indigo experiment stays reverted (iris is violet)" do
    offenders =
      for {path, src} <- web_sources(), String.contains?(src, "indigo-"), do: path

    assert offenders == [], "indigo-* classes found (iris is the violet family): #{inspect(offenders)}"
  end

  test "needs-you speaks flame (orange), never amber, in the card family" do
    files = [
      "lib/loopyard_web/live/workspace_live/messages/cards.ex",
      "lib/loopyard_web/components/stream_card.ex",
      "lib/loopyard_web/live/review_live.ex"
    ]

    offenders = for f <- files, String.contains?(File.read!(f), "amber-"), do: f

    assert offenders == [],
           "amber-* in needs-you surfaces (brand: flame ≡ orange asks; amber is transitional caution only): #{inspect(offenders)}"
  end

  test "every phx-hook referenced in templates exists in app.js" do
    js = File.read!("assets/js/app.js")

    hooks =
      for {_path, src} <- web_sources(),
          [_, hook] <- Regex.scan(~r/phx-hook="([A-Za-z0-9_]+)"/, src),
          uniq: true,
          do: hook

    missing = Enum.reject(hooks, &String.contains?(js, "Hooks.#{&1}"))
    assert missing == [], "templates reference hooks missing from app.js: #{inspect(missing)}"
  end

  test "the in-between-state baseline exists (phx-*-loading styled)" do
    css = File.read!("assets/css/app.css")

    assert String.contains?(css, ".phx-click-loading") and
             String.contains?(css, ".phx-submit-loading"),
           "every user input needs its in-flight state — the global phx-*-loading rules are the floor"
  end

  test "every LiveView that renders chat_panel handles its PerfProbe events" do
    # chat_panel carries the PerfProbe hook, which pushes "perf_sample" to the
    # HOST LiveView. A host without the handler CRASHES on every jank report
    # (FunctionClauseError → remount) — the exact "app feels unreliable" bug.
    offenders =
      for path <- Path.wildcard("lib/loopyard_web/live/**/*.ex"),
          src = File.read!(path),
          # hosts only: actual LiveViews that RENDER the panel (not the
          # component module that defines it)
          String.contains?(src, "use LoopyardWeb, :live_view"),
          String.contains?(src, "<.chat_panel"),
          not String.contains?(src, "perf_sample"),
          do: path

    assert offenders == [],
           "these render chat_panel but don't handle \"perf_sample\": #{inspect(offenders)}"
  end

  test "the old Brand module path is gone (it lives in packages/brand)" do
    offenders =
      for {path, src} <- web_sources(),
          String.contains?(src, "LoopyardWeb.Components.Brand"),
          do: path

    assert offenders == [], "use the packaged `Brand` module: #{inspect(offenders)}"
  end

  test "chat type scale: chat surfaces don't reintroduce ad-hoc prose sizes" do
    # The stream reads from THREE tokens (chat-body/sub/meta). text-lg/text-base
    # in the chat renderers means someone is bypassing the scale.
    files = [
      "lib/loopyard_web/live/workspace_live/messages.ex",
      "lib/loopyard_web/live/workspace_live/messages/cards.ex"
    ]

    offenders =
      for f <- files,
          Regex.match?(~r/text-(?:lg|base)\b/, File.read!(f)),
          do: f

    assert offenders == [],
           "ad-hoc text sizes in chat surfaces (use chat-body/chat-sub/chat-meta): #{inspect(offenders)}"
  end
end
