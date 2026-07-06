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
    case File.read(path(id)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      _ ->
        %{}
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
      all(id) |> Map.put(key, value) |> save(id)
      :ok
    else
      {:error, :invalid_key}
    end
  end

  @doc "Remove an env var."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(key, id) do
    all(id) |> Map.delete(key) |> save(id)
    :ok
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
    vol = Workstation.home_volume(id)
    b64 = id |> env_file_body() |> Base.encode64()

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

    script =
      "mkdir -p /vol/.local/bin && " <>
        "for t in #{tools}; do " <>
        "src=$(command -v $t 2>/dev/null) || continue; " <>
        "[ -x /vol/.local/bin/$t ] && continue; " <>
        "cp \"$src\" /vol/.local/bin/$t; " <>
        "done && " <>
        "touch /vol/.profile && " <>
        "(grep -q '.local/bin' /vol/.profile 2>/dev/null || " <>
        ~s|printf '\\n%s\\n' 'export PATH="$HOME/.local/bin:$PATH"' >> /vol/.profile)|

    case Loopyard.Docker.docker(["run", "--rm", "-v", "#{vol}:/vol", image, "sh", "-c", script]) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # The body of ~/.loopyard/env: `export K='V'` lines, single-quote-escaped so a
  # value containing `'` survives (`'` → `'\''`).
  defp env_file_body(id) do
    all(id)
    |> Enum.sort()
    |> Enum.map_join("\n", fn {k, v} -> "export #{k}='#{String.replace(v, "'", "'\\''")}'" end)
  end

  defp save(map, id) do
    File.mkdir_p!(Path.dirname(path(id)))
    File.write!(path(id), Jason.encode!(map))
    _ = File.chmod(path(id), 0o600)
    :ok
  end

  defp path(id), do: Path.join(Workstation.dir(id), "env.json")
end
