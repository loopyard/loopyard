defmodule Aural.Router do
  @moduledoc """
  Router helper for hosts. Mounts the stream + diag routes the
  `:aural` package needs, plus a `/` → `/<channel_id>` redirect
  for the bare entry point.

      defmodule MyAppWeb.Router do
        use Phoenix.Router
        import Aural.Router

        # No CSRF, plain media. Add this pipeline so the chunked MP3
        # endpoint doesn't get filtered through the :browser pipeline.
        pipeline :aural do
          plug :accepts, ["*/*", "json", "html", "mpeg"]
        end

        scope "/aural" do
          pipe_through :aural
          aural_routes()
        end
      end

  The LiveView route stays in the host's `:browser` scope so it
  picks up the host's root layout and CSRF. Example:

      scope "/" do
        pipe_through :browser
        live "/aural/:channel_id", MyAppWeb.AuralLive, :index
      end

  `aural_routes/0` only mounts the bits that have NO host-specific
  rendering: the stream, the diag, and the bare-entry redirect.
  """

  defmacro aural_routes do
    quote do
      get "/", AuralWeb.RedirectController, :new_channel
      get "/:channel_id/stream.mp3", AuralWeb.StreamController, :stream
      post "/diag", AuralWeb.StreamController, :diag
    end
  end
end
