defmodule Loopyard.Workstation.Integration do
  @moduledoc """
  Registry of workstation integrations — each tool you might connect (GitHub,
  Claude, Codex, Fly…). Every entry is **data**: a label, a one-line blurb,
  optional alternatives (a `:env` token slot, a `:console` terminal command with
  an optional `:console_label` for the button), a "connected?" probe, and a
  markdown doc (`priv/integrations/<id>.md`).

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
      blurb:
        "Clone private repos, push, and use the gh CLI. Connect from your phone — no laptop needed.",
      env: "GITHUB_TOKEN",
      # Phone-native connect: this IS GitHub's OAuth *device flow*, so it needs no
      # fixed callback URL — GitHub hosts the verification page. Run headless in the
      # box console it prints a one-time code + `github.com/login/device`; open that
      # on your PHONE, enter the code, approve. The flags pre-answer gh's interactive
      # prompts (github.com / HTTPS / web / no SSH key) and `< /dev/null` drops the
      # TTY "Press Enter to open a browser" step there's no browser for — so it jumps
      # straight to the code. The login lands in the box's persistent $HOME volume
      # (~/.config/gh), so it survives Restart with no token to copy anywhere.
      console:
        "gh auth login --hostname github.com --git-protocol https --web --skip-ssh-key < /dev/null",
      # Tidy button label — the full flag soup above would overflow on a phone.
      console_label: "gh auth login (device flow)",
      check: {:console, "gh auth status", "Logged in"},
      lands: "gh login in the box $HOME — live now, persists across Restart"
    },
    %{
      id: "claude",
      label: "Claude",
      blurb:
        "Run Claude Code in the box on your Claude subscription. Reconnect from your phone — no laptop needed.",
      env: "CLAUDE_CODE_OAUTH_TOKEN",
      # Phone-native re-auth: `claude setup-token` runs headless in the box
      # console — it prints an auth URL you open on your PHONE, and because the
      # container can't reach the local callback it shows a code you paste back
      # into the terminal. Out it comes a long-lived (1-year) token you drop in
      # the CLAUDE_CODE_OAUTH_TOKEN box below. No trusted-machine browser, no
      # `~/.claude` files, none of the short-lived-credential 401 treadmill.
      console: "claude setup-token",
      check: {:env, "CLAUDE_CODE_OAUTH_TOKEN"},
      lands: "CLAUDE_CODE_OAUTH_TOKEN — durable 1-year token; agents reload themselves"
    },
    %{
      id: "codex",
      label: "Codex",
      blurb:
        "Run Codex in the box as a full agent harness — pick it per agent in the model picker.",
      env: "OPENAI_API_KEY",
      # Either path authenticates the codex-acp harness: `codex login` writes
      # ~/.codex/auth.json (survives Restart in the $HOME volume), or drop an
      # OPENAI_API_KEY / CODEX_API_KEY in the env box below.
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
      lands: "FLY_ACCESS_TOKEN — agents reload themselves"
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
      # Onboarding config so interactive `claude` doesn't re-prompt. Push the Mac's
      # ~/.claude.json as-is (it already has hasCompletedOnboarding) — no python/jq,
      # runs on any machine; minimal fallback if it's absent.
      if [ -f "$HOME/.claude.json" ]; then
        curl #{cf} -T "$HOME/.claude.json" "#{cfg_url}"
      else
        printf '{"hasCompletedOnboarding":true}' | curl #{cf} -T - "#{cfg_url}"
      fi
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
