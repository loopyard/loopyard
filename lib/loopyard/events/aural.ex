defmodule Loopyard.Events.Aural do
  @moduledoc """
  Operator → client ambient-sound commands. Track selection + activity level are
  server-side (`Aural.Channel`), but play/pause/volume live in the browser's
  `<audio>` element (the client-side `AmbientAudio` engine, for autoplay-gesture
  reasons). So the operator's `music` tool broadcasts a Command here; the operator
  LiveView forwards it to its client as a pushed event, which the `AmbientAudio`
  JS hook applies (and the sound pill reflects via `ambient:changed`).

  Sole broadcaster for the `aural:command` topic (PubSub boundary — see
  test/loopyard/pubsub_boundary_test.exs).
  """
  @topic "aural:command"

  defmodule Command do
    @moduledoc "A client-side ambient command: :play | :pause | :volume (value 0.0–1.0)."
    defstruct [:action, :value]
  end

  def subscribe, do: Phoenix.PubSub.subscribe(Loopyard.PubSub, @topic)

  @spec command(:play | :pause | :volume, float() | nil) :: :ok | {:error, term()}
  def command(action, value \\ nil) when action in [:play, :pause, :volume] do
    Phoenix.PubSub.broadcast(Loopyard.PubSub, @topic, %Command{action: action, value: value})
  end
end
