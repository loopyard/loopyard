defmodule Loopyard.Agent.Backend.ACP.SystemPrompt do
  @moduledoc """
  Installs Loopyard's agent system prompt where the ACP harness will read it.

  claude-code-acp has no `append_system_prompt` — it reads `CLAUDE.md` /
  `CLAUDE.local.md` from the session cwd (validated; both are honored together).
  We write a **managed block** into `CLAUDE.local.md` so:

    * the project's own `CLAUDE.md` (mirrored by `ChatAgent.ClaudeContext`) is
      never touched, and
    * any pre-existing `CLAUDE.local.md` content is preserved.

  Idempotent: re-installing replaces only the managed block.

  The sentinels are **plain text**, NOT HTML comments — validated finding: the
  harness ignores content wrapped in `<!-- ... -->` comments, so the prompt must
  be plain markdown for it to take effect.

  Host mode writes to the cwd directly. In-container mode must write the same
  file into the code volume (via `VolumeIO`) so the in-container harness sees it
  — deferred until that path can be validated end to end.
  """
  @filename "CLAUDE.local.md"
  @begin "=== LOOPYARD AGENT INSTRUCTIONS (managed — do not edit) ==="
  @stop "=== END LOOPYARD AGENT INSTRUCTIONS ==="

  @doc "Install (or replace) Loopyard's managed prompt block in `cwd/CLAUDE.local.md`."
  @spec install(String.t(), String.t()) :: :ok | {:error, term()}
  def install(cwd, prompt) when is_binary(cwd) and is_binary(prompt) do
    path = Path.join(cwd, @filename)

    existing =
      case File.read(path) do
        {:ok, content} -> content
        _ -> ""
      end

    File.write(path, render(strip(existing), prompt))
  end

  @doc "Render the managed-block content for a prompt (pure; for tests/volume writers)."
  @spec render_file(String.t(), String.t()) :: String.t()
  def render_file(existing, prompt), do: render(strip(existing), prompt)

  @spec filename() :: String.t()
  def filename, do: @filename

  defp render(preserved, prompt) do
    block = @begin <> "\n\n" <> String.trim(prompt) <> "\n\n" <> @stop <> "\n"

    case String.trim(preserved) do
      "" -> block
      kept -> kept <> "\n\n" <> block
    end
  end

  # Remove any previously-installed managed block (idempotency).
  defp strip(content) do
    Regex.replace(~r/#{Regex.escape(@begin)}.*?#{Regex.escape(@stop)}\n?/s, content, "")
  end
end
