defmodule BoomLooperWeb.Live.ChatLive.Components.Formatters do
  @moduledoc "Pure formatting helpers: service_status_text, exit_reason, time_ago, derive_volume_description."

  def service_status_text(%{status: :running}), do: nil
  def service_status_text(%{status: :starting}), do: "starting"
  def service_status_text(%{status: :crashed}), do: nil
  def service_status_text(%{status: :stopped}), do: nil
  def service_status_text(_), do: nil

  def exit_reason(%{oom_killed: true}), do: "OOM killed"
  def exit_reason(%{error: error}) when is_binary(error), do: error
  def exit_reason(%{exit_code: 0}), do: "exited cleanly"
  def exit_reason(%{exit_code: 137}), do: "killed (SIGKILL)"
  def exit_reason(%{exit_code: 143}), do: "stopped (SIGTERM)"
  def exit_reason(%{exit_code: code}), do: "exit code #{code}"
  def exit_reason(_), do: "stopped"

  def time_ago(nil), do: ""

  def time_ago(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  def derive_volume_description(name) do
    # Fallback for volumes without explicit description
    cond do
      String.contains?(name, "code") -> "Source code"
      String.contains?(name, "cache") -> "Build cache"
      String.contains?(name, "deps") -> "Dependencies"
      String.contains?(name, "postgres") -> "PostgreSQL data"
      String.contains?(name, "redis") -> "Redis data"
      String.contains?(name, "minio") -> "MinIO storage"
      true -> name
    end
  end
end
