defmodule Loopyard.Workstation.Integration do
  @moduledoc """
  Registry of workstation integrations — each tool you might connect (GitHub,
  Claude, Codex, Fly…). Every entry is **data**: a label, a one-line blurb, the
  default **"run it on your Mac"** command that transfers the credential, optional
  alternatives (a `:env` token slot, a `:console` terminal command), a "connected?"
  probe, and a markdown doc (`priv/integrations/<id>.md`).

  The connect model is **Mac-first**: the default path is a single command you run
  on your Mac (where you're already logged in) that pipes the credential into the
  box. `set env var` and `use the terminal` are the *other ways*, not the front
  door. Adding a tool = a markdown file + a map entry here.

  Integrations are **additive** — nothing here is required for an agent to run.
  """
  alias Loopyard.Workstation.{Container, Env}

  @integrations [
    %{
      id: "github",
      label: "GitHub",
      blurb: "Clone private repos, push, and use the gh CLI — give the box your GitHub login.",
      mac_produces: "gh auth token",
      mac_target: {:env, "GITHUB_TOKEN"},
      env: "GITHUB_TOKEN",
      console: "gh auth login",
      check: {:console, "gh auth status", "Logged in"},
      lands: "GITHUB_TOKEN — restart to apply"
    },
    %{
      id: "claude",
      label: "Claude",
      blurb: "Run Claude Code in the box using your Claude subscription.",
      mac_produces: "cat ~/.claude/.credentials.json",
      mac_target: {:file, ".claude/.credentials.json"},
      env: "CLAUDE_CODE_OAUTH_TOKEN",
      console: nil,
      check: {:file, ".claude/.credentials.json"},
      lands: "~/.claude — live, every agent inherits it"
    },
    %{
      id: "codex",
      label: "Codex",
      blurb: "Use the OpenAI Codex CLI in the box with your login.",
      mac_produces: "cat ~/.codex/auth.json",
      mac_target: {:file, ".codex/auth.json"},
      env: "OPENAI_API_KEY",
      console: "codex login",
      check: {:file, ".codex/auth.json"},
      lands: "~/.codex — live, every agent inherits it"
    },
    %{
      id: "fly",
      label: "Fly",
      blurb: "Deploy to Fly.io from the box.",
      mac_produces: "fly auth token",
      mac_target: {:env, "FLY_ACCESS_TOKEN"},
      env: "FLY_ACCESS_TOKEN",
      console: nil,
      check: {:env, "FLY_ACCESS_TOKEN"},
      lands: "FLY_ACCESS_TOKEN — restart to apply"
    }
  ]

  @doc "All integrations (display order)."
  def all, do: @integrations

  @doc "One integration by id, or nil."
  def get(id), do: Enum.find(@integrations, &(&1.id == id))

  @doc "The raw markdown doc for an integration (single source for humans + agents)."
  @spec doc(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def doc(id) do
    path = Application.app_dir(:loopyard, "priv/integrations/#{id}.md")

    case File.read(path) do
      {:ok, md} -> {:ok, md}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The **default** "run it on your Mac" command: produce the credential where you're
  logged in, pipe it into this workstation. One copy-paste, no terminal-fishing.
  """
  @spec mac_command(map(), String.t(), String.t()) :: String.t()
  def mac_command(%{mac_produces: produces, mac_target: target}, base, ws) do
    "#{produces} | curl -fsS -T - #{base}/workstations/#{ws}/#{endpoint(target)}"
  end

  defp endpoint({:env, key}), do: "env/#{key}"
  defp endpoint({:file, path}), do: "file/#{path}"

  @doc """
  Cheap "is this connected?" probe for a given workstation `id`. Greps a marker
  rather than trusting exit codes; `:env` is just a key lookup.
  """
  @spec connected?(map(), String.t()) :: boolean()
  def connected?(%{check: {:env, key}}, id), do: key in Env.keys(id)

  def connected?(%{check: {:file, rel}}, id) do
    exec_says?("test -f '/root/#{rel}' && echo CONNECTED", "CONNECTED", id)
  end

  def connected?(%{check: {:console, cmd, marker}}, id) do
    exec_says?(cmd, marker, id)
  end

  def connected?(_, _id), do: false

  defp exec_says?(cmd, marker, id) do
    case Container.exec(cmd, id) do
      {:ok, out} -> String.contains?(out, marker)
      {:error, out} when is_binary(out) -> String.contains?(out, marker)
      _ -> false
    end
  end
end
