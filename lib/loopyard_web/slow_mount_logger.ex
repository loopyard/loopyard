defmodule LoopyardWeb.SlowMountLogger do
  @moduledoc """
  Telemetry handler that logs a warning whenever a LiveView mount or
  handle_params callback takes longer than `@threshold_us` microseconds.

  This is the production safety net for the "Mount must render instantly"
  rule. The `:timer.tc` test catches violations locally; this catches
  them in production when a Docker daemon hiccup or filesystem stall
  turns a 30ms mount into a 5s mount.

  Phoenix.LiveView already emits these telemetry events out of the box:
    [:phoenix, :live_view, :mount, :stop]
    [:phoenix, :live_view, :handle_params, :stop]
    [:phoenix, :live_view, :handle_event, :stop]

  We attach a single handler per event during application start
  (`Loopyard.Application.start/2` calls `attach/0`).
  """

  require Logger

  # 500ms — same threshold as the :timer.tc tests. If a callback exceeds
  # this in production, log loud so we notice before users complain.
  @threshold_us 500_000

  @events [
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :handle_params, :stop],
    [:phoenix, :live_view, :handle_event, :stop]
  ]

  def attach do
    :telemetry.attach_many(
      "loopyard-slow-mount",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def detach do
    :telemetry.detach("loopyard-slow-mount")
  end

  @doc """
  Telemetry callback. Public so tests can invoke it directly without
  going through the global telemetry registry (which would race with
  the real handler).
  """
  def handle_event(event, %{duration: duration_native}, metadata, _config) do
    duration_us = System.convert_time_unit(duration_native, :native, :microsecond)

    if duration_us > @threshold_us do
      callback = event |> Enum.at(2) |> to_string()
      module = inspect(metadata[:socket] && metadata.socket.view)

      Logger.warning(
        "[SlowMount] #{module} #{callback} took #{div(duration_us, 1000)}ms " <>
          "(threshold #{div(@threshold_us, 1000)}ms). Move slow calls into start_async/3. " <>
          "See CLAUDE.md → 'Mount must render instantly'."
      )
    end

    :ok
  end

  @doc false
  def threshold_us, do: @threshold_us
end
