defmodule LoopyardWeb.Showcase.Scene do
  @moduledoc """
  A showcase SCENE — SwiftUI-preview-style: a named, canned state for a real
  view component. Think Xcode previews for LiveView: the component stays a
  pure function of assigns (the decoupling that keeps this maintainable — the
  LiveView loads state, the component just renders it), and a scene is nothing
  but a name + that component + mock assigns.

  Scenes exist so marketing screenshots (`mix loopyard.shot`) and quick visual
  checks never need the control plane running — no Docker, no agents, no
  server. If a surface can't be a scene, that's the smell that it's reading
  ETS/GenServers from inside the render; extract its render into a component
  that takes assigns and it becomes previewable for free.

  A scene module:

      defmodule LoopyardWeb.Showcase.Scenes.MyScene do
        use LoopyardWeb.Showcase.Scene,
          name: "my-scene",
          description: "What this shows off"

        @impl true
        def component, do: &SomeModule.some_component/1

        @impl true
        def assigns, do: %{...mock data...}
      end

  Register it in `LoopyardWeb.Showcase.@scenes` and it's shootable.
  """

  @doc "The component function (arity-1, takes assigns) this scene renders."
  @callback component() :: (map() -> Phoenix.LiveView.Rendered.t())

  @doc "The canned assigns — ALL state the component needs, no globals."
  @callback assigns() :: map()

  @doc """
  How the rendered component is framed in the page:
  `:pane` — a full-viewport-height flex column (app-like surfaces: chat).
  `:flow` — normal document flow with breathing room (cards, small parts).
  """
  @callback frame() :: :pane | :flow

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)

    quote do
      @behaviour LoopyardWeb.Showcase.Scene

      def name, do: unquote(name)
      def description, do: unquote(description)

      @impl true
      def frame, do: :pane

      defoverridable frame: 0
    end
  end
end
