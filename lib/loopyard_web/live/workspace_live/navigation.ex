defmodule LoopyardWeb.Live.WorkspaceLive.Navigation do
  @moduledoc """
  Where a workspace window lands and how agent presets kick off. Extracted from
  `LoopyardWeb.WorkspaceLive` to keep that module under its size cap.
  """

  @doc """
  Where to send a window that lands on the bare workspace (`:index`) URL when
  agents exist: this window's last meaningful view here (so a switch resumes
  where you were — `WindowViews`), else the latest agent's chat. Returns `nil`
  when we're already there (no redirect needed) — avoids a navigate loop.
  """
  def landing_target(socket) do
    base = socket.assigns.base_path
    ws_id = socket.assigns.workspace.id
    resume = Loopyard.WindowViews.resume_path(socket.transport_pid, ws_id)

    target =
      if is_binary(resume) and resume != base do
        resume
      else
        case List.first(socket.assigns.agents) do
          %{id: id} -> "#{base}/agents/#{id}"
          _ -> nil
        end
      end

    if target && target != base, do: target
  end

  @doc "The kick-off message for a spawn preset, or nil for the default."
  def preset_message("setup") do
    "Look at the project in /workspace and set up a development environment. Start by reading `setup_guide.md` with `read_agent_file` — it has the full playbook."
  end

  def preset_message("debug") do
    "Check `service_status` for all services. For any that are crashed or unhealthy, pull their logs and diagnose the issue. Fix what you can."
  end

  def preset_message("explore") do
    "Explore the project in /workspace. Use `tree` to see the structure, then read key files (README, package.json/Gemfile/mix.exs, config files) and give me a summary of what this project is and how it's built."
  end

  def preset_message(_), do: nil

  # One agent now — it self-determines setup vs coding. Presets only differ in
  # their kick-off message, not the agent.
  def preset_agent_type(_), do: Loopyard.Agents.Registry.default_agent_name()
end
