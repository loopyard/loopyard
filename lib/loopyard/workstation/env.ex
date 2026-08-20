defmodule Loopyard.Workstation.Env do
  @moduledoc """
  Env vars stamped into the workstation console **and** every agent container.

  This is the "pop a token into my workstation" layer: you set `KEY=value` here
  (a long-lived `CLAUDE_CODE_OAUTH_TOKEN`, a `GH_TOKEN`, an API key…), Loopyard
  persists it server-side and injects it as a plain `-e KEY=value` at
  `docker run`. The container just sees a normal env var — it never knows
  Loopyard's store exists. Management is centralized; delivery stays Unix-plain.

  Stored at `<LOOPYARD_HOME>/workstation/env.json` (mode 0600). Changes apply on
  the next container (re)create — i.e. hit **Restart** on the Workstation page.

  Single-user MVP: one global set shared by the console + all agents. Per-user /
  per-workspace scoping is a later refinement (the `Loopyard.Secrets` store
  already models scope if we want to merge them).
  """
  alias Loopyard.Workstation

  @key_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  # Known integrations — rendered as labeled paste slots so setup is "pick the
  # tool, paste the token" instead of "remember the variable name." Still just
  # env vars under the hood. `hint` says exactly how to mint the token.
  # An integration is a set of "ways to get the token", any/all of which render:
  #   * paste     — always; the value input (write-only).
  #   * cli/cli_label — a one-click "Import" that runs `cli` in the container to
  #     read/mint the token from an existing login (e.g. `gh auth token`). nil =
  #     no in-container path (Claude's setup-token needs a desktop browser).
  #   * commands  — runnable-doc steps: `%{cmd, label}` rendered as ▶ Run buttons
  #     that type the command into the console and take you to it. The terminal
  #     lives where we tell you to run things, instead of "go run this elsewhere."
  #   * setup     — :anywhere | :desktop (minting needs a same-machine browser).
  # (OAuth-redirect methods can slot in here later for services that support it.)
  @integrations [
    %{
      key: "GITHUB_TOKEN",
      label: "GitHub",
      hint: "Log in once (device flow — phone-friendly), then import the token.",
      setup: :anywhere,
      commands: [%{cmd: "gh auth login", label: "Run gh auth login"}],
      cli: "gh auth token",
      cli_label: "Import from gh",
      # The command that prints the token on your Mac — piped into the push curl.
      mac: "gh auth token"
    },
    %{
      key: "CLAUDE_CODE_OAUTH_TOKEN",
      label: "Claude",
      hint: "claude setup-token  on your Mac — Claude's loopback auth is hostile to remote",
      setup: :desktop,
      commands: [],
      cli: nil,
      cli_label: nil,
      mac: "claude setup-token"
    },
    %{
      key: "FLY_ACCESS_TOKEN",
      label: "Fly",
      hint: "fly tokens create",
      setup: :anywhere,
      commands: [],
      cli: nil,
      cli_label: nil,
      mac: "fly auth token"
    }
  ]

  @doc "The known integrations rendered as guided slots (label, env key, how-to hint)."
  def integrations, do: @integrations

  @doc "Is `key` currently set?"
  @spec set?(String.t(), String.t()) :: boolean()
  def set?(key, id), do: Map.has_key?(all(id), key)

  @doc "The full env map, `%{\"KEY\" => \"value\"}`."
  @spec all(String.t()) :: %{optional(String.t()) => String.t()}
  def all(id) do
    case read_map(id) do
      {:ok, m} -> m
      _ -> %{}
    end
  end

  # Read the store, distinguishing THREE outcomes so a writer never clobbers:
  #   {:ok, map}       — parsed fine
  #   :absent          — file genuinely doesn't exist yet (an empty store IS the
  #                      correct starting point)
  #   {:error, reason} — file EXISTS but is unreadable / corrupt / truncated.
  #
  # This distinction is load-bearing. The old `all/1` collapsed every failure to
  # `%{}`, so a `put` that read during a truncated write merged its one key onto
  # an assumed-empty map and PERMANENTLY dropped every other token. That is
  # exactly how the identity store decayed to a single key and 401'd the
  # in-container harness (every turn crashed until CLAUDE_CODE_OAUTH_TOKEN was
  # restored). Writers now refuse the `{:error, _}` case instead of clobbering.
  @doc false
  @spec read_map(String.t()) :: {:ok, map()} | :absent | {:error, term()}
  def read_map(id) do
    case File.read(path(id)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> {:ok, m}
          {:ok, _} -> {:error, :not_a_map}
          {:error, reason} -> {:error, {:decode, reason}}
        end

      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The current store for a read-modify-write. Absent → start from empty. A
  # genuine read/parse error → REFUSE (never merge onto an assumed-empty map,
  # which would silently drop the tokens we just failed to read).
  @doc false
  def current_for_write(id) do
    case read_map(id) do
      {:ok, m} -> {:ok, m}
      :absent -> {:ok, %{}}
      {:error, reason} -> {:error, {:store_unreadable, reason}}
    end
  end

  @doc "Sorted list of the env var names (no values)."
  @spec keys(String.t()) :: [String.t()]
  def keys(id), do: all(id) |> Map.keys() |> Enum.sort()

  @doc "Set `key=value`. Validates the name is a legal env var. Overwrites."
  @spec put(String.t(), String.t(), String.t()) :: :ok | {:error, :invalid_key}
  def put(key, value, id) when is_binary(key) and is_binary(value) do
    key = String.trim(key)

    if Regex.match?(@key_re, key) do
      # Read-modify-write via current_for_write/1 so a transient unreadable store
      # can NEVER be treated as empty and clobber the other tokens.
      with {:ok, current} <- current_for_write(id),
           :ok <- save(Map.put(current, key, value), id) do
        # Materialize into the identity's home volume NOW. A running container
        # already mounts that volume, so the new value (e.g. a fresh
        # CLAUDE_CODE_OAUTH_TOKEN) is visible to the next in-container harness
        # session immediately — without restarting the container. Best-effort:
        # a docker hiccup mustn't lose the saved value.
        sync_home(id)
        # sync_home only rescues the NEXT session; a session that's already live
        # holds the token it sourced at launch. When the pushed key is a harness
        # credential, restart the workstation's running agents so they re-source
        # it (each resumes its conversation). This is how "push a fresh token"
        # auto-recovers stranded agents without any manual Restart click.
        maybe_reload_agents(key, id)
        :ok
      end
    else
      {:error, :invalid_key}
    end
  end

  # Credentials the in-container harness authenticates with. Pushing a new value
  # for one of these should reload running sessions; other env vars (build flags,
  # feature toggles) don't need to interrupt an in-flight turn.
  #
  # Covers every harness in `Loopyard.Harness.Catalog`, not just Claude: dropping
  # in an OpenAI key must reload agents the same way, or a Codex harness keeps
  # running unauthenticated until something else happens to restart it.
  @credential_keys ~w(CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY CODEX_API_KEY OPENAI_API_KEY)

  defp maybe_reload_agents(key, id) do
    if key in @credential_keys, do: Loopyard.Workstation.reload_agents(id)
    :ok
  end

  @doc "Remove an env var."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(key, id) do
    with {:ok, current} <- current_for_write(id),
         remaining <- Map.delete(current, key),
         :ok <- save(remaining, id) do
      sync_home_asserted(id, remaining)
      :ok
    end
  end

  @doc "`docker run` args injecting every env var: `[\"-e\", \"K=V\", ...]`."
  @spec env_args(String.t()) :: [String.t()]
  def env_args(id) do
    all(id) |> Enum.flat_map(fn {k, v} -> ["-e", "#{k}=#{v}"] end)
  end

  @doc """
  Materialize the identity's env vars into its `$HOME` volume as a sourced file —
  the **files-in-$HOME** path that replaces `docker run -e` (which leaked secrets
  into `docker inspect`).

  Writes `~/.loopyard/env` (mode 0600) holding `export K='V'` lines and ensures
  `~/.profile` sources it, so a login shell (`Docker.with_login_profile/1`) puts
  the env in scope. Idempotent; call before boot. Runs via a transient
  `docker run --rm` mounting the home volume (auto-creates it if absent), so it
  works whether or not a container is currently up.
  """
  @spec sync_home(String.t()) :: :ok | {:error, term()}
  def sync_home(id) do
    case read_map(id) do
      # NEVER overwrite the container's env with an empty file just because we
      # momentarily couldn't read the store — that would strip a live harness of
      # CLAUDE_CODE_OAUTH_TOKEN and 401 it. Bail, keep the container's good env.
      {:error, reason} ->
        {:error, {:store_unreadable, reason}}

      # An ABSENT store is the same hazard wearing different clothes, and it is
      # the one that actually bit: volume names are NOT scoped by LOOPYARD_HOME,
      # so a process pointed at a different home (the test suite, which
      # redirects LOOPYARD_HOME to a scratch dir) reads "no env.json" and then
      # writes an EMPTY env file into the REAL `loopyard-ws-<id>-home` volume —
      # logging every live agent out of Claude. "I can't find a store" is never
      # a reason to erase one; only a store that EXISTS may assert emptiness.
      :absent ->
        {:error, {:store_absent, path(id)}}

      # An EMPTY store is the same hazard again, and it is the one that actually
      # ran: `mix test` redirects LOOPYARD_HOME to a scratch dir and writes an
      # empty `{}` env.json there — but Docker VOLUME NAMES are global and are
      # NOT scoped by LOOPYARD_HOME, so materializing that `{}` wrote an empty
      # `~/.loopyard/env` into the developer's REAL `loopyard-ws-<id>-home`
      # volume and logged every live agent out of Claude. On every test run.
      #
      # Erasing an identity's whole environment is never something to do as a
      # SIDE EFFECT of a sync. Removing the last var goes through `delete/2`,
      # which says so explicitly.
      {:ok, map} when map_size(map) == 0 ->
        {:error, :refusing_empty_env}

      {:ok, map} ->
        materialize_home(id, map)
    end
  end

  # `delete/2`'s path: the caller is ASSERTING the new (possibly empty) env,
  # rather than syncing whatever it happened to read, so an empty write is
  # intentional here and only here.
  defp sync_home_asserted(id, map), do: materialize_home(id, map)

  defp materialize_home(id, map) do
    vol = Workstation.home_volume(id)

    # This function is the one that writes into a live $HOME volume, so it is
    # the right place to assert the isolation boundary: a name outside this
    # environment's prefix means someone constructed a REAL resource name from
    # a process that should not be able to touch it. Fail here, with a stack
    # trace naming the caller, rather than silently erasing a running
    # identity's credentials.
    prefix = Workstation.resource_prefix()

    unless String.starts_with?(vol, prefix) do
      raise "refusing to write #{inspect(vol)} — outside this environment's prefix #{inspect(prefix)}"
    end

    b64 = map |> env_file_body() |> Base.encode64()

    script =
      "mkdir -p /vol/.loopyard && " <>
        "printf '%s' '#{b64}' | base64 -d > /vol/.loopyard/env && " <>
        "chmod 600 /vol/.loopyard/env && " <>
        "touch /vol/.profile && " <>
        "(grep -q '.loopyard/env' /vol/.profile 2>/dev/null || " <>
        ~s|printf '\\n%s\\n' '[ -f "$HOME/.loopyard/env" ] && . "$HOME/.loopyard/env"' >> /vol/.profile)|

    case Loopyard.Docker.docker([
           "run",
           "--rm",
           "-v",
           "#{vol}:/vol",
           "alpine",
           "sh",
           "-c",
           script
         ]) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # Operator CLIs we carry in the identity home volume so they're
  # available in ANY container that mounts it — including the project's
  # compose `workspace` service, whose app image (ruby/node/…) doesn't
  # ship gh/fly. Static, self-contained binaries only (no shared libs),
  # so a copy from the base image runs unchanged under a different
  # distro. claude is NOT staged — the harness runs it host-side / via
  # ACP, not as a shell command in the project container.
  @staged_tools ~w(gh fly)

  @doc """
  Stage operator CLI binaries (#{Enum.join(@staged_tools, ", ")}) from the
  stock base image into the identity's `$HOME/.local/bin`, and ensure that
  dir is on `PATH` via `~/.profile`. This is what lets `gh` work inside the
  project's `workspace` service — that image has the right language runtime
  but none of the operator toolchain. Idempotent (skips a tool already
  staged) and cheap on the hot path; the base image is local so the
  transient `docker run` doesn't pull. Best-effort: a failure here must not
  block boot, so callers ignore the result.
  """
  @spec stage_tools(String.t()) :: :ok | {:error, term()}
  def stage_tools(id) do
    vol = Workstation.home_volume(id)
    image = Loopyard.Workspace.WorkContainer.image()
    tools = Enum.join(@staged_tools, " ")

    # Make git authenticate to GitHub over https via gh's token-backed
    # credential helper. gh reads GH_TOKEN/GITHUB_TOKEN (which ~/.profile
    # exports) — so `git push`/`pull` just work with the identity's token,
    # and the token NEVER lands in any repo's `.git/config`. Written to the
    # home volume's global gitconfig (HOME=/vol here). Idempotent: only set
    # if unset, so we never clobber a helper the user configured themselves.
    script =
      "mkdir -p /vol/.local/bin && " <>
        "for t in #{tools}; do " <>
        "src=$(command -v $t 2>/dev/null) || continue; " <>
        "[ -x /vol/.local/bin/$t ] && continue; " <>
        "cp \"$src\" /vol/.local/bin/$t; " <>
        "done && " <>
        "touch /vol/.profile && " <>
        "(grep -q '.local/bin' /vol/.profile 2>/dev/null || " <>
        ~s|printf '\\n%s\\n' 'export PATH="$HOME/.local/bin:$PATH"' >> /vol/.profile)| <>
        " && (HOME=/vol git config --global --get 'credential.https://github.com.helper' >/dev/null 2>&1 || " <>
        "HOME=/vol git config --global 'credential.https://github.com.helper' '!gh auth git-credential')"

    case Loopyard.Docker.docker(["run", "--rm", "-v", "#{vol}:/vol", image, "sh", "-c", script]) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # The parts of the driver's host `~/.claude` that make Claude *theirs* —
  # skills, slash commands, custom subagents, and the user-level CLAUDE.md.
  #
  # DISABLED (was `~w(skills commands agents)` + `~w(CLAUDE.md)`): carrying the
  # driver's ENTIRE personal identity into every agent backfired hard. A router
  # skill like `gstack` hijacked workspace agents into dispatching through it
  # ("that's not a gstack skill"), and injecting ~60 skills' preambles blew agent
  # context past 3M tokens. A loopyard workspace agent must keep ITS role + load
  # the PROJECT's own `.claude` (via trust_projects) — not inherit the human's
  # global toolkit. If specific skills are ever wanted in agents, add them as an
  # explicit, curated allowlist here — never the whole dir.
  @claude_identity_dirs ~w()
  @claude_identity_files ~w()

  @doc """
  Sync the driver's Claude identity (#{Enum.join(@claude_identity_dirs, "/, ")}/,
  #{Enum.join(@claude_identity_files, ", ")}) from the host `~/.claude` into the
  identity's home volume, so the in-container harness has the same skills +
  prompts as Claude on the host. Replace-on-sync (host is the source of truth);
  container-generated state (sessions, projects, settings.json, todos) is
  untouched. Idempotent, cheap, best-effort — callers ignore the result. No-op
  when the host has no `~/.claude`.
  """
  @spec sync_claude(String.t()) :: :ok | {:error, term()}
  def sync_claude(id) do
    host_claude = Path.expand("~/.claude")

    if File.dir?(host_claude) do
      vol = Workstation.home_volume(id)

      dirs =
        Enum.map_join(@claude_identity_dirs, " ", fn d ->
          "if [ -d /host/#{d} ]; then rm -rf /vol/.claude/#{d} && cp -R /host/#{d} /vol/.claude/#{d}; fi;"
        end)

      files =
        Enum.map_join(@claude_identity_files, " ", fn f ->
          "if [ -f /host/#{f} ]; then cp /host/#{f} /vol/.claude/#{f}; fi;"
        end)

      script = "mkdir -p /vol/.claude && #{dirs} #{files} true"

      case Loopyard.Docker.docker([
             "run",
             "--rm",
             "-v",
             "#{host_claude}:/host:ro",
             "-v",
             "#{vol}:/vol",
             "alpine",
             "sh",
             "-c",
             script
           ]) do
        {:ok, _} -> :ok
        err -> err
      end
    else
      :ok
    end
  end

  @doc """
  Pre-accept Claude Code's folder-trust dialog for the dirs an in-container
  harness runs in: `/workspace` (every workspace agent's cwd) and `/home/<id>`
  (the operator's cwd). Claude Code REFUSES to load project `CLAUDE.md`,
  `.claude/settings.json`, hooks, and skills from an untrusted directory — and
  in a headless ACP container there is no human to click the dialog, so
  project-level config was silently ignored every session. Loopyard is the one
  that put the code in the volume; trust is its call to make at boot.

  Merges `projects.<dir>.hasTrustDialogAccepted = true` into the identity's
  `~/.claude.json` (the exact key the CLI itself writes), preserving everything
  else in the file. Idempotent, best-effort — callers ignore the result.
  """
  @spec trust_projects(String.t()) :: :ok | {:error, term()}
  def trust_projects(id) do
    vol = Workstation.home_volume(id)

    with {:ok, out} <-
           Loopyard.Docker.docker([
             "run",
             "--rm",
             "-v",
             "#{vol}:/vol",
             "alpine",
             "sh",
             "-c",
             "cat /vol/.claude.json 2>/dev/null || echo {}"
           ]) do
      current =
        case Jason.decode(out) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      projects =
        Enum.reduce(["/workspace", "/home/#{id}"], Map.get(current, "projects", %{}), fn dir,
                                                                                         acc ->
          Map.update(
            acc,
            dir,
            %{"hasTrustDialogAccepted" => true},
            &Map.put(&1, "hasTrustDialogAccepted", true)
          )
        end)

      b64 = current |> Map.put("projects", projects) |> Jason.encode!() |> Base.encode64()

      # ATOMIC replace (tmp + mv). A plain `>` truncates first, and a harness
      # process starting concurrently can read the half-written file and die
      # with exit 1 — which is exactly how the fleet-wide session reload
      # produced "Failed to restart the agent session: {:closed, {:exit_status, 1}}".
      script =
        "printf '%s' '#{b64}' | base64 -d > /vol/.claude.json.tmp && " <>
          "chmod 600 /vol/.claude.json.tmp && mv /vol/.claude.json.tmp /vol/.claude.json"

      case Loopyard.Docker.docker([
             "run",
             "--rm",
             "-v",
             "#{vol}:/vol",
             "alpine",
             "sh",
             "-c",
             script
           ]) do
        {:ok, _} -> :ok
        err -> err
      end
    end
  end

  # The body of ~/.loopyard/env: `export K='V'` lines, single-quote-escaped so a
  # value containing `'` survives (`'` → `'\''`). Takes the already-read map (not
  # an id) so sync_home materializes the EXACT map it validated — no second read
  # that could race to a different (or empty) state.
  defp env_file_body(map) do
    map
    |> Enum.sort()
    |> Enum.map_join("\n", fn {k, v} -> "export #{k}='#{String.replace(v, "'", "'\\''")}'" end)
  end

  # ATOMIC write: encode to a temp file, then rename over the target. A plain
  # File.write! truncates the target FIRST, so a concurrent reader (another put,
  # or sync_home) can observe a half-written / empty file, decode `{}`, and drop
  # keys. tmp + rename means every reader sees either the whole old file or the
  # whole new one — never a torn state.
  defp save(map, id) do
    p = path(id)
    File.mkdir_p!(Path.dirname(p))
    tmp = p <> ".tmp"
    File.write!(tmp, Jason.encode!(map))
    _ = File.chmod(tmp, 0o600)
    File.rename!(tmp, p)
    :ok
  end

  defp path(id), do: Path.join(Workstation.dir(id), "env.json")
end
