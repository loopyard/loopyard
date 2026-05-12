defmodule Loopyard.StreamBuffer do
  @moduledoc """
  Accumulates streaming output (build logs, exec output) with a rolling
  byte window. Manages the lifecycle of a single streaming message within
  a message list: create on first chunk, update in place on subsequent
  chunks, restore from existing content on page reload.

  Pure data — no GenServer, no PubSub, no side effects. Designed to be
  called from LiveView assigns or anywhere else that needs "show existing
  content + stream new data" with a size cap.
  """

  @default_max_bytes 8_000

  defstruct content: "",
            msg_id: nil,
            title: nil,
            max_bytes: @default_max_bytes

  @type t :: %__MODULE__{
          content: String.t(),
          msg_id: String.t() | nil,
          title: String.t() | nil,
          max_bytes: pos_integer()
        }

  @doc "Create a new empty buffer."
  def new(opts \\ []) do
    %__MODULE__{
      max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes)
    }
  end

  @doc """
  Restore a buffer from an existing build message (page reload).
  Seeds the buffer with the message's content and ID so subsequent
  stream data appends correctly.
  """
  def restore(message, opts \\ [])
  def restore(nil, _opts), do: new()

  def restore(message, opts) do
    %__MODULE__{
      content: message[:content] || "",
      msg_id: message[:id],
      title: message[:title],
      max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes)
    }
  end

  @doc """
  Append new data to the buffer. Trims to the rolling byte window.
  Assigns a message ID if one doesn't exist yet.
  """
  def append(%__MODULE__{} = buf, data, opts \\ []) do
    content = buf.content <> data
    content = trim(content, buf.max_bytes)

    title = Keyword.get(opts, :title, buf.title)
    msg_id = Keyword.get(opts, :msg_id, buf.msg_id) || generate_id()

    %{buf | content: content, msg_id: msg_id, title: title}
  end

  @doc """
  Build a message map from the current buffer state.
  """
  def to_message(%__MODULE__{} = buf) do
    %{
      id: buf.msg_id,
      role: :build,
      content: buf.content,
      title: buf.title,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Upsert the buffer's message into a message list.
  If a `:build` message already exists, replaces it in place.
  Otherwise appends.
  """
  def upsert_message(%__MODULE__{} = buf, messages) when is_list(messages) do
    msg = to_message(buf)

    if Enum.any?(messages, &(&1.role == :build)) do
      Enum.map(messages, fn
        %{role: :build} -> msg
        other -> other
      end)
    else
      messages ++ [msg]
    end
  end

  @doc "Whether the buffer has any content."
  def empty?(%__MODULE__{content: ""}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc "Byte size of the current content."
  def size(%__MODULE__{content: content}), do: byte_size(content)

  # --- Private ---

  defp trim(content, max_bytes) when byte_size(content) > max_bytes do
    String.slice(content, -max_bytes..-1//1)
  end

  defp trim(content, _), do: content

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
