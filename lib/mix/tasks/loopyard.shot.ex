defmodule Mix.Tasks.Loopyard.Shot do
  @shortdoc "Screenshot showcase scenes at mobile + desktop viewports"

  @moduledoc """
  Render showcase scenes (real components + mock data — no server, no Docker)
  and screenshot them with headless Chrome. The marketing-shot pipeline.

      mix loopyard.shot                       # every scene, both viewports
      mix loopyard.shot chat-working          # one scene
      mix loopyard.shot --viewport mobile     # one viewport
      mix loopyard.shot --out ../website/priv/content/marketing/features/shots
      mix loopyard.shot --list                # what scenes exist

  Output: `<out>/<scene>-<viewport>.png` (default out: `tmp/showcase`).
  Viewports: mobile 390×844, desktop 1120×780 — both captured at 2× for
  retina-crisp marketing images.

  Add a scene: drop a module in `lib/loopyard_web/showcase/scenes/` (see
  `LoopyardWeb.Showcase.Scene`) and register it in `LoopyardWeb.Showcase`.
  """

  use Mix.Task

  # Desktop is deliberately NARROW (1120): marketing figures display at
  # ~1100-1150px, so the capture is ~1:1 at display width — the app's text
  # reads at native size instead of thumbnail scale.
  @viewports %{
    "mobile" => {390, 844},
    "desktop" => {1120, 780}
  }

  # Chrome headless clamps window width to roughly this; see shoot/2.
  @chrome_min_width 500

  @chrome_paths [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
  ]

  @impl true
  def run(argv) do
    {opts, scene_names} =
      OptionParser.parse!(argv,
        strict: [viewport: :string, out: :string, list: :boolean, theme: :string]
      )

    # Compile only — the full app (Docker observers, registries, agents) is
    # exactly what this pipeline exists to avoid booting.
    Mix.Task.run("compile")

    if opts[:list] do
      for s <- LoopyardWeb.Showcase.scenes() do
        Mix.shell().info("#{String.pad_trailing(s.name(), 18)} #{s.description()}")
      end
    else
      shoot(scene_names, opts)
    end
  end

  defp shoot(scene_names, opts) do
    scenes = resolve_scenes(scene_names)
    viewports = resolve_viewports(opts[:viewport])
    out_dir = opts[:out] || "tmp/showcase"
    File.mkdir_p!(out_dir)
    chrome = chrome_bin!()

    theme = resolve_theme(opts[:theme])

    for scene <- scenes do
      for {vp_name, {w, h}} <- viewports do
        # Chrome headless silently clamps windows to ~500px wide — a "390px"
        # window is really 500 and the layout overflows the shot. So narrow
        # viewports render in a legal-width window with the scene FRAMED at
        # the true width (page_html centers it), then the PNG is center-
        # cropped down to the frame. Media queries bucket 500 with 390.
        win_w = max(w, @chrome_min_width)
        frame_width = if win_w != w, do: w

        html = LoopyardWeb.Showcase.page_html(scene, theme, frame_width)

        html_path =
          Path.join(System.tmp_dir!(), "loopyard-shot-#{scene.name()}-#{vp_name}.html")

        File.write!(html_path, html)

        suffix = if theme == :dark, do: "-dark", else: ""
        out = Path.expand(Path.join(out_dir, "#{scene.name()}-#{vp_name}#{suffix}.png"))

        {output, status} =
          System.cmd(
            chrome,
            [
              "--headless=new",
              "--disable-gpu",
              "--hide-scrollbars",
              "--force-device-scale-factor=2",
              "--window-size=#{win_w},#{h}",
              "--screenshot=#{out}",
              "--virtual-time-budget=2000",
              "file://#{html_path}"
            ],
            stderr_to_stdout: true
          )

        with true <- status == 0 and File.exists?(out),
             :ok <- crop(out, frame_width, h) do
          Mix.shell().info("✓ #{out}")
        else
          _ -> Mix.raise("Chrome failed for #{scene.name()}/#{vp_name}:\n#{output}")
        end
      end
    end
  end

  # Center-crop back to the framed width (2× for the retina scale factor).
  # sips ships with macOS; on Linux fall back to ImageMagick's convert.
  defp crop(_out, nil, _h), do: :ok

  defp crop(out, frame_width, h) do
    {px_w, px_h} = {frame_width * 2, h * 2}

    cond do
      System.find_executable("sips") ->
        {_, 0} = System.cmd("sips", ["-c", "#{px_h}", "#{px_w}", out], stderr_to_stdout: true)
        :ok

      System.find_executable("magick") ->
        {_, 0} =
          System.cmd(
            "magick",
            [out, "-gravity", "center", "-crop", "#{px_w}x#{px_h}+0+0", "+repage", out],
            stderr_to_stdout: true
          )

        :ok

      true ->
        {:error, :no_crop_tool}
    end
  end

  defp resolve_scenes([]), do: LoopyardWeb.Showcase.scenes()

  defp resolve_scenes(names) do
    Enum.map(names, fn name ->
      LoopyardWeb.Showcase.get(name) ||
        Mix.raise(
          "Unknown scene #{inspect(name)}. Known: " <>
            Enum.map_join(LoopyardWeb.Showcase.scenes(), ", ", & &1.name())
        )
    end)
  end

  defp resolve_theme(nil), do: :light
  defp resolve_theme("light"), do: :light
  defp resolve_theme("dark"), do: :dark
  defp resolve_theme(other), do: Mix.raise("Unknown theme #{inspect(other)} (light | dark)")

  defp resolve_viewports(nil), do: @viewports

  defp resolve_viewports(spec) do
    spec
    |> String.split(",", trim: true)
    |> Map.new(fn name ->
      case @viewports[name] do
        nil -> Mix.raise("Unknown viewport #{inspect(name)} (mobile | desktop)")
        dims -> {name, dims}
      end
    end)
  end

  defp chrome_bin! do
    System.get_env("LOOPYARD_CHROME") ||
      Enum.find(@chrome_paths, &File.exists?/1) ||
      System.find_executable("chromium") ||
      Mix.raise(
        "No Chrome/Chromium found. Install Google Chrome or set LOOPYARD_CHROME."
      )
  end
end
