defmodule Loopyard.Workstation.Integration do
  @moduledoc """
  Registry of workstation integrations — each tool you might connect (GitHub,
  Claude, Codex, Fly…). Every entry is **data**: a label, a one-line blurb,
  optional alternatives (a `:env` token slot, a `:console` terminal command), a
  "connected?" probe, and a markdown doc (`priv/integrations/<id>.md`).

  The connect model is **Mac-first**: the default path is a command you run on your
  Mac (where you're already logged in) that transfers the login into the box. The
  per-tool transfer script (`mac_script/4`) is **keychain-aware**: on macOS, `gh`
  and Claude keep credentials in the Keychain (not files), so a naive
  `cat ~/.claude/.credentials.json` finds nothing. The scripts read the Keychain
  (with a Linux file fallback), and — for Claude — also push the minimal
  `~/.claude.json` onboarding config, without which *interactive* `claude` re-runs
  its login flow even with valid credentials. Same scripts power `setup.sh`.

  Integrations are **additive** — nothing here is required for an agent to run.
  """
  alias Loopyard.Workstation.{Container, Env}

  @integrations [
    %{
      id: "github",
      label: "GitHub",
      blurb: "Clone private repos, push, and use the gh CLI — give the box your GitHub login.",
      env: "GITHUB_TOKEN",
      console: "gh auth login",
      check: {:console, "gh auth status", "Logged in"},
      lands: "gh login (live) + GITHUB_TOKEN env (Restart)"
    },
    %{
      id: "claude",
      label: "Claude",
      blurb: "Run Claude Code in the box using your Claude subscription.",
      env: "CLAUDE_CODE_OAUTH_TOKEN",
      console: nil,
      # The recommended headless path is a long-lived (1-year) token from
      # `claude setup-token`, delivered as CLAUDE_CODE_OAUTH_TOKEN — not the
      # short-lived ~/.claude/.credentials.json (which 401s within hours).
      check: {:env, "CLAUDE_CODE_OAUTH_TOKEN"},
      lands: "CLAUDE_CODE_OAUTH_TOKEN — durable 1-year token; restart to apply"
    },
    %{
      id: "codex",
      label: "Codex",
      blurb: "Use the OpenAI Codex CLI in the box with your login.",
      env: "OPENAI_API_KEY",
      console: "codex login",
      check: {:file, ".codex/auth.json"},
      lands: "~/.codex — live, every agent inherits it"
    },
    %{
      id: "fly",
      label: "Fly",
      blurb: "Deploy to Fly.io from the box.",
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
  The host-side shell that transfers this tool's login into workstation `ws`.

  Run on the Mac where you're logged in. Keychain-aware (with a Linux file
  fallback) and guarded — it pushes nothing if the credential isn't found, so a
  missing tool never writes an empty file. `curl_flags` lets the caller add flags
  (e.g. the push-token header for a remote `setup.sh`); the default is the bare,
  local form shown on the tool page.
  """
  @spec mac_script(map(), String.t(), String.t(), String.t()) :: String.t()
  def mac_script(integration, base, ws, curl_flags \\ "-fsS")

  def mac_script(%{id: "github"}, base, ws, cf) do
    env = url(base, ws, "env/GITHUB_TOKEN")
    hosts = url(base, ws, "file/.config/gh/hosts.yml")

    """
    if command -v gh >/dev/null 2>&1; then
      t=$(gh auth token 2>/dev/null)
      if [ -n "$t" ]; then
        printf '%s' "$t" | curl #{cf} -T - "#{env}"
        printf 'github.com:\\n    oauth_token: %s\\n    user: %s\\n    git_protocol: ssh\\n' "$t" "$(gh api user -q .login 2>/dev/null)" | curl #{cf} -T - "#{hosts}"
      fi
    fi\
    """
  end

  def mac_script(%{id: "claude"}, base, ws, cf) do
    creds_url = url(base, ws, "file/.claude/.credentials.json")
    cfg_url = url(base, ws, "file/.claude.json")

    """
    c=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || cat "$HOME/.claude/.credentials.json" 2>/dev/null)
    if [ -n "$c" ]; then
      printf '%s' "$c" | curl #{cf} -T - "#{creds_url}"
      cfg=$(python3 -c 'import json,os,sys; d=json.load(open(os.path.expanduser("~/.claude.json"))); k=["hasCompletedOnboarding","oauthAccount","userID","lastOnboardingVersion","firstStartTime","claudeCodeFirstTokenDate","numStartups","tipsHistory"]; o={x:d[x] for x in k if x in d}; o["hasCompletedOnboarding"]=True; sys.stdout.write(json.dumps(o))' 2>/dev/null)
      [ -n "$cfg" ] || cfg='{"hasCompletedOnboarding":true}'
      printf '%s' "$cfg" | curl #{cf} -T - "#{cfg_url}"
    fi\
    """
  end

  def mac_script(%{id: "codex"}, base, ws, cf) do
    file = url(base, ws, "file/.codex/auth.json")

    """
    [ -f "$HOME/.codex/auth.json" ] && cat "$HOME/.codex/auth.json" | curl #{cf} -T - "#{file}"\
    """
  end

  def mac_script(%{id: "fly"}, base, ws, cf) do
    env = url(base, ws, "env/FLY_ACCESS_TOKEN")

    """
    command -v fly >/dev/null 2>&1 && t=$(fly auth token 2>/dev/null) && [ -n "$t" ] && printf '%s' "$t" | curl #{cf} -T - "#{env}"\
    """
  end

  defp url(base, ws, path), do: "#{base}/workstations/#{ws}/#{path}"

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
