defmodule LoopyardWeb.Showcase do
  @moduledoc """
  The scene registry + static renderer behind `mix loopyard.shot`.

  Renders a scene (a real view component + canned assigns — see
  `LoopyardWeb.Showcase.Scene`) to a fully self-contained HTML page: the
  compiled app CSS inlined, the root-layout body classes applied, no server,
  no JS, no control plane. Chrome headless then screenshots that file at any
  viewport. LiveComponents inside the tree render statically (their
  mount/update run; events obviously don't fire — screenshots don't click).
  """

  # render_component/3 is a macro that reads @endpoint from the caller — the
  # same contract LiveView tests use. No server needs to be running; the
  # endpoint module is only used for config lookups during render.
  require Phoenix.LiveViewTest
  @endpoint LoopyardWeb.Endpoint

  @scenes [
    LoopyardWeb.Showcase.Scenes.ChatWorking,
    LoopyardWeb.Showcase.Scenes.QuestionCard,
    LoopyardWeb.Showcase.Scenes.WorkspaceFull,
    LoopyardWeb.Showcase.Scenes.WorkspaceQuestion,
    LoopyardWeb.Showcase.Scenes.DevServer,
    LoopyardWeb.Showcase.Scenes.MultiAgent,
    LoopyardWeb.Showcase.Scenes.SshConsole,
    LoopyardWeb.Showcase.Scenes.Operator,
    LoopyardWeb.Showcase.Scenes.Aural
  ]

  def scenes, do: @scenes

  def get(name), do: Enum.find(@scenes, &(&1.name() == name))

  @doc """
  Render a scene module to a self-contained HTML page (a binary).

  `theme` forces light or dark DETERMINISTICALLY: headless Chrome inherits the
  host OS appearance, so shots would differ machine-to-machine. The app's dark
  styles all live behind `@media (prefers-color-scheme: dark)` (Tailwind
  `darkMode: 'media'`), so rewriting that one query — to never-match for
  light, always-match for dark — pins the theme without touching the CSS.

  `frame_width` pins the scene to an exact CSS-pixel width inside a wider
  window. Chrome headless refuses windows narrower than ~500px, so a true
  phone shot (390px) renders in a 500px window with the scene constrained +
  centered here, and `mix loopyard.shot` center-crops the PNG down to the
  frame. Media queries see the 500px window — same mobile bucket as 390.
  """
  def page_html(scene, theme \\ :light, frame_width \\ nil) do
    ensure_endpoint_term()

    inner =
      Phoenix.LiveViewTest.render_component(scene.component(), scene.assigns())

    css =
      :loopyard
      |> :code.priv_dir()
      |> Path.join("static/assets/app.css")
      |> File.read!()
      |> force_theme(theme)

    constraint =
      if frame_width, do: ~s( style="width:#{frame_width}px;margin:0 auto"), else: ""

    framed =
      case scene.frame() do
        :pane ->
          ~s(<div class="h-full flex flex-col min-h-0 bg-brand-paper dark:bg-brand-ink"#{constraint}>#{inner}</div>)

        :flow ->
          ~s(<div class="p-6 bg-brand-paper dark:bg-brand-ink min-h-full"#{constraint}>#{inner}</div>)
      end

    """
    <!DOCTYPE html>
    <html lang="en" class="h-full bg-brand-paper dark:bg-brand-ink">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>#{scene.name()}</title>
      <style>#{css}</style>
    </head>
    <body class="h-full antialiased font-sans">
      #{framed}
      <script>
        // The live app bottom-anchors the transcript (newest message above the
        // composer). A static render sits at scrollTop 0, which screenshots
        // the OLDEST content — snap to the tail like the real thing.
        addEventListener("load", () => {
          const m = document.getElementById("messages");
          if (m) m.scrollTop = m.scrollHeight;
        });
      </script>
    </body>
    </html>
    """
  end

  # Some components call endpoint path/url helpers (e.g. ~p for static
  # assets), which read the persistent term Phoenix.Endpoint.Supervisor puts
  # at boot. Scenes render WITHOUT the app running, so stub the same shape
  # (mirrors deps/phoenix/lib/phoenix/endpoint/supervisor.ex) when the real
  # endpoint hasn't claimed it. Never overwrites a live endpoint's term.
  defp ensure_endpoint_term do
    key = {Phoenix.Endpoint, LoopyardWeb.Endpoint}

    if :persistent_term.get(key, nil) == nil do
      url = URI.parse("http://loopyard.local")

      :persistent_term.put(key, %{
        struct_url: url,
        url: URI.to_string(url),
        host: url.host,
        path: "",
        script_name: [],
        static_path: "",
        static_url: URI.to_string(url)
      })
    end

    :ok
  end

  @dark_query "@media (prefers-color-scheme: dark)"

  defp force_theme(css, :light), do: String.replace(css, @dark_query, "@media not all")
  defp force_theme(css, :dark), do: String.replace(css, @dark_query, "@media all")
end
