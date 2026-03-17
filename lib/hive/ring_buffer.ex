defmodule Hive.RingBuffer do
  @moduledoc """
  A simple ring buffer that stores binary data up to a maximum byte size.
  Used to cap agent terminal output so it doesn't grow unbounded.
  """

  @default_max_bytes 256 * 1024  # 256 KB

  defstruct chunks: :queue.new(), total_bytes: 0, max_bytes: @default_max_bytes

  @type t :: %__MODULE__{
    chunks: :queue.queue(binary()),
    total_bytes: non_neg_integer(),
    max_bytes: pos_integer()
  }

  @spec new(pos_integer()) :: t()
  def new(max_bytes \\ @default_max_bytes) do
    %__MODULE__{max_bytes: max_bytes}
  end

  @spec append(t(), binary()) :: t()
  def append(%__MODULE__{} = buf, data) when is_binary(data) do
    new_buf = %{buf | chunks: :queue.in(data, buf.chunks), total_bytes: buf.total_bytes + byte_size(data)}
    trim(new_buf)
  end

  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{chunks: chunks}) do
    chunks |> :queue.to_list() |> IO.iodata_to_binary()
  end

  @spec byte_size_total(t()) :: non_neg_integer()
  def byte_size_total(%__MODULE__{total_bytes: total}), do: total

  defp trim(%__MODULE__{total_bytes: total, max_bytes: max} = buf) when total <= max, do: buf

  defp trim(%__MODULE__{chunks: chunks, total_bytes: total} = buf) do
    case :queue.out(chunks) do
      {{:value, chunk}, rest} ->
        new_total = total - byte_size(chunk)
        trim(%{buf | chunks: rest, total_bytes: new_total})

      {:empty, _} ->
        %{buf | total_bytes: 0}
    end
  end
end
