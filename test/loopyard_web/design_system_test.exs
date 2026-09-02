defmodule LoopyardWeb.DesignSystemTest do
  @moduledoc """
  STATIC GUARDRAILS for the design system — greps over the web layer that fail
  the build when an architecture rule regresses. Each assertion encodes a rule
  that was violated once and cost a debugging session; see docs/CODE_RULES.md
  ("Design system") for the why behind each.
  """
  use ExUnit.Case, async: true

  @web_root "lib/loopyard_web"

  setup_all do
    sources =
      Path.wildcard("#{@web_root}/**/*.{ex,heex}")
      |> Enum.map(&{&1, File.read!(&1)})

    %{sources: sources}
  end

  defp web_sources, do: Process.get(:web_sources) || cache_sources()

  defp cache_sources do
    sources =
      Path.wildcard("#{@web_root}/**/*.{ex,heex}")
      |> Enum.map(&{&1, File.read!(&1)})

    Process.put(:web_sources, sources)
    sources
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

    assert offenders == [],
           "indigo-* classes found (iris is the violet family): #{inspect(offenders)}"
  end

  test "needs-you speaks flame (orange), never amber, in the card family" do
    files = [
      "lib/loopyard_web/live/workspace_live/messages/cards.ex",
      "lib/loopyard_web/components/stream_card.ex",
      "lib/loopyard_web/live/notifications_live.ex"
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

  test "the type scale is five tokens, everywhere, with no escapes" do
    # It once rendered NINE sizes — 13, 14, 14.25, 15, 15.2, 16, 18, 20, 24 —
    # with four of them inside a 2px band. Differences that small can't read as
    # hierarchy, but they're plainly visible as inconsistency, which is exactly
    # how they read. The scale is now meta/body/lead/title/hero and Tailwind's
    # default sizes are REPLACED rather than extended, so `text-sm` generates no
    # CSS at all. This test catches the ones a build can't: leftovers, arbitrary
    # values, and the chat's old private tokens.
    banned = ~r/\b(?:text-(?:xs|sm|base|lg|xl|[2-9]xl|\[[^\]]+\])|chat-(?:body|sub|meta))\b/

    offenders =
      web_sources()
      |> Enum.filter(fn {_p, src} -> Regex.match?(banned, src) end)
      |> Enum.map(fn {p, _} -> Path.relative_to_cwd(p) end)

    assert offenders == [],
           """
           Off-scale text sizes. Use text-meta (13) / text-body (16) /
           text-lead (18) / text-title (20) / text-hero (24) — see the scale
           at the top of assets/tailwind.config.js.

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}
           """
  end

  test "the scale's sizes are responsive, and defined in exactly one place" do
    # Phone LARGER, desktop smaller — a phone is small, often in motion and
    # held at arm's length; a desktop display is stationary and closer. The
    # sizes live in CSS custom properties so the whole scale shifts at ONE
    # breakpoint, which is what lets every template keep a single class and
    # still be right at both widths.
    config = File.read!("assets/tailwind.config.js")

    for token <- ~w(meta body lead title hero) do
      assert config =~ "#{token}: ['var(--t-#{token})'",
             "#{token} must take its size from --t-#{token}, not a hardcoded value"
    end

    css = File.read!("assets/css/app.css")
    assert css =~ ~r/:root\s*\{[^}]*--t-body:/, "the phone scale must be defined on :root"

    assert css =~ ~r/@media \(min-width: 768px\)\s*\{\s*:root/,
           "the desktop scale must be the ONE media query that shifts it"

    # Inheritance has to land ON the scale: components that deliberately take
    # their size from context were falling back to the browser's 16px, which
    # the scale doesn't contain — that's why the switcher read smaller than
    # the mono port chip beside it.
    assert css =~ ~r/body\s*\{[^}]*font-size:\s*var\(--t-body\)/,
           "body must inherit from the scale, not the browser default"
  end

  test "the top chrome is PINNED, from one owner" do
    # This reads like a native app: primary and secondary nav stay put while
    # content scrolls, so you can switch modes without scrolling back up.
    #
    # It used to only LOOK pinned. The chat and operator shells scroll an inner
    # container, so their static bar never moved; on the pages where the
    # DOCUMENT scrolls (/ and /system) the same component slid away. Identical
    # markup, opposite behaviour depending on the shell — the kind of thing
    # nobody notices until they're on the page that's wrong.
    css = File.read!("assets/css/app.css")

    assert css =~ ~r/\.app-bar\s*\{[^}]*sticky/, "the primary bar must pin"
    assert css =~ ~r/\.app-bar-secondary\s*\{[^}]*sticky/, "so must the secondary row"

    # Sticky content scrolls UNDER, not around — without its own background the
    # bar is transparent and the text runs through it.
    assert css =~ ~r/\.app-bar\s*\{[^}]*bg-brand-paper/,
           "a sticky bar needs an opaque background"

    # Every top bar takes it from the class, not by hand-rolling sticky.
    bars =
      web_sources()
      |> Enum.filter(fn {_p, src} -> src =~ ~r/h-14[^"]*border-b/ end)
      |> Enum.reject(fn {_p, src} -> src =~ "app-bar" end)
      |> Enum.map(fn {p, _} -> Path.relative_to_cwd(p) end)

    assert bars == [], "these top bars don't use the shared pinned class: #{inspect(bars)}"
  end

  test "no element changes size between breakpoints" do
    # A responsive size flip (text-lead md:text-body) means the same element is
    # two sizes depending on the window — the page's own title changing size
    # when you rotate. If a size is right, it's right at every width.
    offenders =
      Path.wildcard("lib/loopyard_web/**/*.{ex,heex}")
      |> Enum.filter(
        &Regex.match?(~r/\b(?:sm|md|lg|xl):text-(?:meta|body|lead|title|hero)\b/, File.read!(&1))
      )
      |> Enum.map(&Path.relative_to_cwd/1)

    assert offenders == [],
           "responsive font-size flips: #{inspect(offenders)}"
  end

  test "safe-area-top lives on page shells ONLY (one inset per page, ever)" do
    # THE RULE (docs/CODE_RULES.md): the outermost page shell owns
    # safe-area-top exactly once; bars/components never apply it. A second
    # application stacked a giant dead band on top of the PWA ("safe insets
    # is all fucked"). New page shell → add its file here deliberately.
    allowed =
      MapSet.new([
        "lib/loopyard_web/components/app_shell.ex",
        "lib/loopyard_web/components/common.ex",
        "lib/loopyard_web/components/focused_view.ex",
        "lib/loopyard_web/live/dashboard_live.ex",
        "lib/loopyard_web/live/message_live.ex",
        "lib/loopyard_web/live/agent_live.ex",
        "lib/loopyard_web/live/notifications_live.ex",
        "lib/loopyard_web/live/sound_live.ex",
        "lib/loopyard_web/live/workspace_live.ex"
      ])

    offenders =
      Path.wildcard("lib/loopyard_web/**/*.ex")
      |> Enum.filter(&String.contains?(File.read!(&1), "safe-area-top"))
      |> Enum.reject(&MapSet.member?(allowed, &1))

    assert offenders == [],
           "safe-area-top outside the page-shell allowlist (components/bars " <>
             "must never apply it — the shell already does): #{inspect(offenders)}"

    # And never twice in one file.
    doubled =
      Enum.filter(allowed, fn f ->
        length(String.split(File.read!(f), "safe-area-top")) - 1 > 1
      end)

    assert doubled == [], "safe-area-top applied more than once in: #{inspect(doubled)}"
  end
end
