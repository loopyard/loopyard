defmodule Loopyard.ChatAgent.StreamHandler.FailedTurn do
  @moduledoc """
  What a turn that failed for good says, and whether it is worth retrying —
  extracted from `StreamHandler` (which sits at its size cap).

  A turn whose harness died because the Docker VM's disk is full (the
  connection classifies it `{:disk_full, …}`, see
  `Harness.ACP.Connection.Diagnostics.close_error/2`) is NOT retried — every
  retry would relaunch into the same full disk — and is NOT blamed on the API:
  it gets `Loopyard.Docker.Disk.agent_copy/0`, which names the one action.
  """

  alias Loopyard.Docker.Disk

  @doc "Did this turn fail because the Docker disk is full?"
  @spec disk_full?(term()) :: boolean()
  def disk_full?(reason) when is_binary(reason), do: Disk.full_error?(reason)
  def disk_full?({:disk_full, _}), do: true
  def disk_full?(reason), do: Disk.full_error?(inspect(reason))

  @doc "The chat line for a turn handed back to the human."
  @spec copy(term(), non_neg_integer()) :: String.t()
  def copy(reason, attempts) do
    if disk_full?(reason) do
      Disk.agent_copy()
    else
      retried = if attempts > 0, do: " after #{attempts} automatic retries", else: ""

      "This didn't go through — Anthropic's API failed#{retried} " <>
        "(#{inspect(reason)}). Send it again."
    end
  end
end
