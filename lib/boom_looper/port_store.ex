defmodule BoomLooper.PortStore do
  @moduledoc """
  JSON persistence for `BoomLooper.PortRegistry`.

  One file at `~/.boomlooper/ports.json` holds every port registry
  entry. On boot, `PortRegistry.restore/0` reads this file (or seeds
  from legacy `Compose.capture_port_map/1` if it doesn't exist) and
  inserts the entries into the `:port_registry` ETS table. On every
  assign/release, `PortRegistry` writes the whole store back.

  Shape:

      {
        "version": 1,
        "port_range": [4000, 9999],
        "entries": [
          {"workspace_id":"dd73","service":"dev","container_port":3000,
           "host_port":4012,"exposed":false,"legacy":false,
           "allocated_at":"2026-04-15T..."}
        ]
      }

  The range in the file is informational — the runtime range comes
  from app config. Writing it into the file just makes the audit
  answer to "what range was this written under?" trivial.
  """

  require Logger

  @version 1
  @filename "ports.json"

  @doc "Absolute path to the store file."
  def path do
    Path.join(BoomLooper.Workspace.home_dir(), @filename)
  end

  @doc """
  Load entries from disk. Returns `[]` when the file is missing or
  unreadable — the caller (PortRegistry.restore/0) decides whether to
  seed from legacy state or start empty.
  """
  def load do
    case File.read(path()) do
      {:ok, content} ->
        decode(content)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("[PortStore] Could not read #{path()}: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Write the given list of entries to disk. Whole-file replace; the
  store is small and write frequency is low (one write per assign /
  release, not per request), so there's no point in append semantics.
  """
  def save(entries, port_range) when is_list(entries) do
    File.mkdir_p!(BoomLooper.Workspace.home_dir())

    payload = %{
      "version" => @version,
      "port_range" => [port_range.first, port_range.last],
      "entries" => Enum.map(entries, &encode_entry/1)
    }

    File.write!(path(), Jason.encode!(payload, pretty: true))
    :ok
  end

  # --- Private ---

  defp decode(content) do
    case Jason.decode(content) do
      {:ok, %{"version" => @version, "entries" => entries}} when is_list(entries) ->
        Enum.map(entries, &decode_entry/1)

      {:ok, %{"version" => other}} ->
        Logger.warning(
          "[PortStore] Unknown version #{inspect(other)} in #{path()} — ignoring contents. " <>
            "Bump @version + add a migration when changing the on-disk shape."
        )

        []

      {:ok, _} ->
        Logger.warning("[PortStore] Malformed store at #{path()} — ignoring contents.")
        []

      {:error, reason} ->
        Logger.warning("[PortStore] Invalid JSON at #{path()}: #{inspect(reason)}")
        []
    end
  end

  defp decode_entry(%{
         "workspace_id" => ws,
         "service" => svc,
         "container_port" => cport,
         "host_port" => hport
       } = entry) do
    %{
      workspace_id: ws,
      service: svc,
      container_port: cport,
      host_port: hport,
      exposed: Map.get(entry, "exposed", false),
      legacy: Map.get(entry, "legacy", false),
      allocated_at: parse_datetime(Map.get(entry, "allocated_at"))
    }
  end

  defp encode_entry(%{
         workspace_id: ws,
         service: svc,
         container_port: cport,
         host_port: hport
       } = entry) do
    %{
      "workspace_id" => ws,
      "service" => svc,
      "container_port" => cport,
      "host_port" => hport,
      "exposed" => Map.get(entry, :exposed, false),
      "legacy" => Map.get(entry, :legacy, false),
      "allocated_at" =>
        case Map.get(entry, :allocated_at) do
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          nil -> nil
        end
    }
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
