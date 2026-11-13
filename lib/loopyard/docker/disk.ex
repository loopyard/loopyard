defmodule Loopyard.Docker.Disk do
  @moduledoc """
  Free space in the Docker VM — the pure half of `Loopyard.Docker.DiskMonitor`.

  When the VM's disk fills, `docker exec` fails with "no space left on device"
  and every agent turn dies looking like a harness crash (issue #117). This
  module reads a `df -P` of a container's root (the overlay root lives on the
  disk that holds `/var/lib/docker`, so it IS the VM's free space), turns a
  reading into a `Loopyard.Health` status, recognises the ENOSPC wording in a
  failed command's output, and builds the ONE inbox item that names the cause
  and the action.

  No Docker calls here; `probe/0` (the impure part) lives in the monitor.
  """

  alias Loopyard.Notifications.Item

  @type reading :: %{free_bytes: non_neg_integer(), total_bytes: non_neg_integer()}
  @type observation :: reading() | :full | nil

  # Defaults; overridable via `:docker_disk_degraded_free_bytes` /
  # `:docker_disk_down_free_bytes` (docs/CONFIG.md).
  @default_degraded 5_000_000_000
  @default_down 500_000_000

  @alert_id "docker-disk"

  @doc "Below this many free bytes the disk is degraded."
  def degraded_bytes,
    do: Application.get_env(:loopyard, :docker_disk_degraded_free_bytes, @default_degraded)

  @doc "Below this many free bytes writes fail (or are about to): down."
  def down_bytes, do: Application.get_env(:loopyard, :docker_disk_down_free_bytes, @default_down)

  @doc "The inbox item's id (one item, ever — raised, updated, settled)."
  def alert_id, do: @alert_id

  @doc """
  Parse `df -P` output for one filesystem into bytes. Reads the block size
  from the header (`1024-blocks`, `512-blocks`; default 1024) and finds the
  data columns relative to the `NN%` capacity column, so a filesystem or mount
  name with spaces doesn't shift them.
  """
  @spec parse_df(String.t()) :: {:ok, reading()} | {:error, String.t()}
  def parse_df(output) when is_binary(output) do
    lines = output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

    with [header | rows] when rows != [] <- lines,
         {:ok, block} <- block_size(header),
         {:ok, total, avail} <- columns(List.last(rows)) do
      {:ok, %{free_bytes: avail * block, total_bytes: total * block}}
    else
      _ -> {:error, "unrecognised df output: " <> String.slice(output, 0, 200)}
    end
  end

  def parse_df(_), do: {:error, "unrecognised df output"}

  defp block_size(header) do
    case Regex.run(~r/(\d+)-blocks/, header) do
      [_, n] -> {:ok, String.to_integer(n)}
      nil -> if header =~ ~r/^Filesystem/i, do: {:ok, 1024}, else: :error
    end
  end

  defp columns(row) do
    fields = String.split(row, ~r/\s+/, trim: true)

    case Enum.find_index(fields, &String.match?(&1, ~r/^\d+%$/)) do
      idx when is_integer(idx) and idx >= 3 ->
        with [t, _u, a] <- Enum.slice(fields, idx - 3, 3),
             {total, ""} <- Integer.parse(t),
             {avail, ""} <- Integer.parse(a) do
          {:ok, total, avail}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc """
  Does this command output say the disk is full? Docker phrases it "no space
  left on device" (the errno text) — from `exec`, `run`, `cp`, the OCI
  runtime, or the adapter's own stderr. Matched loosely, case-insensitively.
  """
  @spec full_error?(term()) :: boolean()
  def full_error?(text) when is_binary(text),
    do: text =~ ~r/no space left on device|\bENOSPC\b/i

  def full_error?(_), do: false

  @doc """
  The health status for an observation: `nil` (no reading yet) is healthy,
  `:full` (a write already failed with ENOSPC) is down, a reading is graded
  against the thresholds.
  """
  @spec status(observation(), keyword()) ::
          :healthy | {:degraded, String.t()} | {:down, String.t()}
  def status(observation, opts \\ [])
  def status(nil, _opts), do: :healthy

  def status(:full, _opts),
    do: {:down, "Docker VM disk is full — writes fail with \"no space left on device\""}

  def status(%{free_bytes: free, total_bytes: total}, opts) do
    down = Keyword.get(opts, :down_bytes, down_bytes())
    degraded = Keyword.get(opts, :degraded_bytes, degraded_bytes())
    figure = "#{human_bytes(free)} free of #{human_bytes(total)}"

    cond do
      free < down ->
        {:down, figure <> " in the Docker VM — writes are failing or about to"}

      free < degraded ->
        {:degraded, figure <> " in the Docker VM (below #{human_bytes(degraded)})"}

      true ->
        :healthy
    end
  end

  @doc "`:healthy | :degraded | :down` — the part of a status that drives the inbox."
  def level(:healthy), do: :healthy
  def level({level, _}) when level in [:degraded, :down], do: level

  @doc """
  Bytes as a short DECIMAL figure (`165 MB`, `4.2 GB`) — the units Docker and
  `df -H` print, so a reading matches `docker system df`. (The UI's
  `LoopyardWeb.Format.format_bytes/1` is binary — 1024-based.)
  """
  @spec human_bytes(non_neg_integer()) :: String.t()
  def human_bytes(b) when b >= 1_000_000_000_000, do: decimal(b / 1_000_000_000_000, "TB")
  def human_bytes(b) when b >= 1_000_000_000, do: decimal(b / 1_000_000_000, "GB")
  def human_bytes(b) when b >= 1_000_000, do: "#{round(b / 1_000_000)} MB"
  def human_bytes(b) when b >= 1_000, do: "#{round(b / 1_000)} kB"
  def human_bytes(b) when is_integer(b), do: "#{b} B"
  def human_bytes(_), do: "?"

  defp decimal(x, unit) when x >= 10, do: "#{round(x)} #{unit}"
  defp decimal(x, unit), do: "#{Float.round(x, 1)} #{unit}"

  @doc """
  The inbox item for a degraded/down status. ONE id, so re-raising updates
  the same item; the label is the cause, the meta carries the one action.
  """
  @spec alert_item(:degraded | :down, :healthy | {atom(), String.t()}) :: Item.t()
  def alert_item(level, status) when level in [:degraded, :down] do
    reason =
      case status do
        {_, r} -> r
        _ -> "Docker VM disk is low"
      end

    %Item{
      id: @alert_id,
      kind: :alert,
      status: :open,
      agent_id: "loopyard",
      agent_name: "Loopyard",
      path: "/system/docker",
      msg_id: @alert_id,
      scope: :system,
      label: headline(level) <> " — " <> reason,
      raised_at: DateTime.utc_now(),
      meta: %{level: level, action: action()}
    }
  end

  defp headline(:down), do: "Agents can't run: the Docker disk is full"
  defp headline(:degraded), do: "The Docker disk is nearly full"

  @doc "The one action, in words."
  def action do
    # Plain text: the inbox card prints it as written, so backticks would show.
    "Loopyard removes its own leftovers automatically. The rest is yours to decide: " <>
      "open Docker to remove stopped containers, unused images and old volumes."
  end

  @doc "The line an agent's chat shows when a turn or launch failed on a full disk."
  def agent_copy do
    "This didn't go through — the Docker VM's disk is full, so the harness couldn't run. " <>
      "Free some space (the Notifications inbox and /system say how; `mix loopyard.gc` " <>
      "reclaims Loopyard's own leftovers), then send it again. Your conversation is preserved."
  end
end
