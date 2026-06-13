defmodule Loopyard.Events.Workstation do
  @moduledoc """
  Publisher for the singleton `"workstation"` PubSub topic — image-build
  output + completion for the user's workstation base image.

  The Workstation page (`WorkstationLive`) subscribes so build output streams
  live into the build pane for everyone watching — whether the build was kicked
  off by the human (Save & Rebuild) or by the workstation agent's `rebuild_image`
  tool. Multiplayer by default: one build, every viewer sees it.

  Per the PubSub boundary rule this is the ONLY place these broadcasts happen;
  every subscriber implements the `Subscriber` behaviour with explicit callbacks
  (no `@optional_callbacks`).
  """
  @telemetry [:loopyard, :events, :publish]

  alias Loopyard.Events.Workstation.{BuildOutput, BuildDone}

  @topic "workstation"
  @events [BuildOutput, BuildDone]

  def events, do: @events
  def topic, do: @topic

  def subscribe, do: Phoenix.PubSub.subscribe(Loopyard.PubSub, @topic)

  def publish(%BuildOutput{} = e), do: bcast(e)
  def publish(%BuildDone{} = e), do: bcast(e)

  defp bcast(%mod{} = e) do
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: @topic, event: mod})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, @topic, e)
  end
end

defmodule Loopyard.Events.Workstation.BuildOutput do
  @moduledoc "A chunk of `docker build` output for the workstation image."
  @enforce_keys [:data]
  defstruct [:data]
  @type t :: %__MODULE__{data: String.t()}
end

defmodule Loopyard.Events.Workstation.BuildDone do
  @moduledoc "The workstation image build finished. `result` is `:ok | {:error, term}`."
  @enforce_keys [:result]
  defstruct [:result]
  @type t :: %__MODULE__{result: :ok | {:error, term()}}
end

defmodule Loopyard.Events.Workstation.Subscriber do
  @moduledoc """
  Behaviour for views subscribed to the `"workstation"` topic. Implement every
  callback explicitly (no `@optional_callbacks`).
  """
  alias Loopyard.Events.Workstation

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  @callback on_build_output(Workstation.BuildOutput.t(), socket) :: result
  @callback on_build_done(Workstation.BuildDone.t(), socket) :: result
end
