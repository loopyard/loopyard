defmodule Loopyard.Events.Ambient do
  @moduledoc """
  Publisher for the `"ambient_audio"` PubSub topic.

  Carries binary 16-bit PCM chunks produced by
  `Loopyard.Ambient.Engine`. Subscribers (the AmbientChannel) push
  these chunks to connected browsers, which feed them into WebAudio
  for playback.
  """

  @topic "ambient_audio"
  @telemetry [:loopyard, :events, :publish]

  def topic, do: @topic

  def subscribe, do: Phoenix.PubSub.subscribe(Loopyard.PubSub, @topic)

  @doc """
  Broadcast a chunk of PCM audio. `chunk` is a binary of little-endian
  signed 16-bit samples (mono).
  """
  def publish_chunk(chunk) when is_binary(chunk) do
    :telemetry.execute(@telemetry, %{count: 1, bytes: byte_size(chunk)}, %{
      topic: @topic,
      event: :chunk
    })

    Phoenix.PubSub.broadcast(Loopyard.PubSub, @topic, {:audio_chunk, chunk})
  end
end
