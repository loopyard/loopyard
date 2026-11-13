defmodule Loopyard.Workstation.CredentialFile do
  @moduledoc """
  A harness sign-in that is a FILE, stored WITH a workstation identity and
  delivered per agent — the file-shaped twin of the env-var token
  `Workstation.Env` holds for Claude.

  Which harnesses have one, and what it is called, is data on the Catalog
  entry (`credential_file: %{home_env:, name:}`); nothing here names a vendor.
  Today that is Codex: a ChatGPT-plan sign-in (`codex login --device-auth`) is
  `$CODEX_HOME/auth.json` (default `~/.codex`). What was probed on the v5 base
  image (codex-cli 0.154.0, codex-acp 1.6.0 bundling codex 0.148.0):

    * the file holds the ChatGPT OAuth tokens (`tokens.{id_token,
      access_token, refresh_token, account_id}`, `last_refresh`); the CLI
      prefers an OS keyring but, with none in a container, falls back to the
      file (the sign-in pins `cli_auth_credentials_store=file` to be sure);
    * `CODEX_HOME` relocates the whole directory (config, sessions, the file);
    * codex-acp spawns `codex app-server` with its own env and decides
      "authenticated" by the app-server's `account/read`, i.e. by that file —
      so a per-identity `CODEX_HOME` is all two agents in one container need to
      run on two ChatGPT plans.

  ## Where it lives

    * **Stored copy** — `<LOOPYARD_HOME>/workstations/<id>/credentials/<harness>/<name>`
      (dir 0700, file 0600), written once per guided sign-in (`put/3`).
    * **Delivered copy** — `~/.loopyard/<harness>.<identity>/<name>` (mode 600)
      in the home volume of every work container an agent on that identity
      runs in, plus a `.loopyard-generation` marker naming the stored copy it
      came from. The identity's env file (`~/.loopyard/env.<identity>`, sourced
      at launch by `Harness.ACP.docker_exec_cmd/3`) exports
      `<home_env>="$HOME/.loopyard/<harness>.<identity>"`. A file in `$HOME`,
      never argv or an env value.

  ## Which copy wins

  The CLI REFRESHES the file in place while it runs (new access token, and the
  vendor may rotate the refresh token). Once delivered, the **in-container copy
  is authoritative**: delivery writes only when the file is absent, or when the
  marker names an older stored copy — i.e. the human signed in again, which is
  the one event that should replace a live credential. Re-delivering the stored
  copy on every launch would roll a refreshed file back to a refresh token the
  vendor may already have retired, and sign the agent out.

  Trade-off: an identity that runs as a GUEST in work containers of several
  other identities gets one copy per host home volume, each refreshing on its
  own; if the vendor rotates refresh tokens, the copy that refreshes second can
  be signed out. The fix is to sign in again (a new generation reaches every
  copy on the next launch). The common case — agents on their workspace's own
  identity — shares ONE home volume and so one copy. Harvesting the freshest
  copy back into the store is tracked in docs/IMPROVEMENTS.md.

  A guest identity WITHOUT a stored sign-in still gets its own (empty)
  directory exported, so its agents fail to sign in rather than silently
  billing the host identity's `~/.codex` — the same rule the env file's
  `unset` enforces for tokens.
  """

  alias Loopyard.Harness.Catalog
  alias Loopyard.Workstation

  @marker ".loopyard-generation"
  @max_bytes 256 * 1024

  @doc "Every Catalog harness with a file-shaped sign-in, with its spec."
  @spec harnesses() :: [{atom(), Catalog.credential_file()}]
  def harnesses do
    for %{credential_file: spec, id: id} <- Catalog.all(), do: {id, spec}
  end

  @doc "The env vars that relocate a credential directory (unset per identity, like tokens)."
  @spec home_envs() :: [String.t()]
  def home_envs, do: Enum.map(harnesses(), fn {_id, spec} -> spec.home_env end)

  @doc """
  Store a sign-in file for `identity`. The body must be a JSON object (what
  the CLI writes) and is never logged. Then materializes the identity's home
  files, reloads the agents that run on it (they relaunch and pick it up) and
  announces the change — key only.
  """
  @spec put(String.t(), atom(), binary()) :: :ok | {:error, term()}
  def put(identity, harness, body) when is_binary(identity) and is_binary(body) do
    with {:ok, spec} <- spec(harness),
         true <- Workstation.valid_id?(identity) or {:error, :invalid_identity},
         :ok <- validate(body) do
      write_atomic(path(identity, harness, spec), body)
      _ = Workstation.Env.sync_home(identity)
      Workstation.reload_agents(identity)

      Loopyard.Events.Workstation.publish(%Loopyard.Events.Workstation.CredentialsChanged{
        workstation_id: identity,
        source: :file,
        key: Atom.to_string(harness)
      })

      :ok
    end
  end

  @doc "Is a sign-in file stored for `identity` and `harness`?"
  @spec stored?(String.t(), atom()) :: boolean()
  def stored?(identity, harness) do
    case spec(harness) do
      {:ok, spec} -> is_binary(identity) and File.regular?(path(identity, harness, spec))
      _ -> false
    end
  end

  @doc "Does `identity` hold any stored sign-in file?"
  @spec any_stored?(String.t()) :: boolean()
  def any_stored?(identity), do: Enum.any?(harnesses(), fn {id, _} -> stored?(identity, id) end)

  @doc "The in-container directory (relative to `$HOME`) an identity's copy lives in."
  @spec home_dir(atom(), String.t()) :: String.t()
  def home_dir(harness, identity), do: ".loopyard/#{harness}.#{identity}"

  @doc """
  Lines for `~/.loopyard/env.<identity>`: export each credential directory the
  identity has a stored sign-in for — and, when `guest?` (the file goes into
  ANOTHER identity's home), every one, so a missing sign-in fails loudly
  instead of falling through to the host's own login.
  """
  @spec exports(String.t(), boolean()) :: String.t()
  def exports(identity, guest?) do
    for {id, spec} <- harnesses(), guest? or stored?(identity, id), into: "" do
      ~s|export #{spec.home_env}="$HOME/#{home_dir(id, identity)}"\n|
    end
  end

  @doc """
  The shell that materializes `identity`'s stored sign-ins under `root` (a home
  volume's mount point). Writes a file only when it is absent or the marker
  names a different stored generation (see "Which copy wins"). A pure string:
  `Env` runs it in its transient volume container; tests run it in a tmp dir.
  Empty when there is nothing to deliver (and no guest directory to make).
  """
  @spec deliver_script(String.t(), String.t(), boolean()) :: String.t()
  def deliver_script(identity, root, guest?) do
    for {id, spec} <- harnesses(), into: "" do
      # Double-quoted: the script is `sh -c`'s own argv (no outer quoting
      # layer), and a root may hold spaces. Identity ids are validated
      # (`Workstation.valid_id?/1`) and the rest is ours.
      dir = ~s|"#{root}/#{home_dir(id, identity)}"|

      case read(identity, id, spec) do
        {:ok, body} ->
          gen = generation(body)
          file = ~s|"#{root}/#{home_dir(id, identity)}/#{spec.name}|
          tmp = file <> ~s|.tmp"|
          file = file <> ~s|"|
          marker = ~s|"#{root}/#{home_dir(id, identity)}/#{@marker}"|

          "mkdir -p #{dir} && chmod 700 #{dir} && " <>
            "if [ ! -f #{file} ] || [ \"$(cat #{marker} 2>/dev/null)\" != #{gen} ]; then " <>
            "printf %s #{Base.encode64(body)} | base64 -d > #{tmp} && " <>
            "chmod 600 #{tmp} && mv #{tmp} #{file} && printf %s #{gen} > #{marker}; " <>
            "fi && "

        :none when guest? ->
          "mkdir -p #{dir} && chmod 700 #{dir} && "

        :none ->
          ""
      end
    end
  end

  @doc "A stored copy's generation: a short content hash (no secret in it)."
  @spec generation(binary()) :: String.t()
  def generation(body),
    do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  # ── internals ────────────────────────────────────────────────────────────

  defp spec(harness) do
    case List.keyfind(harnesses(), harness, 0) do
      {_, spec} -> {:ok, spec}
      nil -> {:error, :no_credential_file}
    end
  end

  defp read(identity, harness, spec) do
    case File.read(path(identity, harness, spec)) do
      {:ok, body} -> {:ok, body}
      _ -> :none
    end
  end

  defp validate(body) when byte_size(body) > @max_bytes, do: {:error, :too_large}

  defp validate(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) and map_size(map) > 0 -> :ok
      _ -> {:error, :not_a_credential}
    end
  end

  defp path(identity, harness, spec),
    do: Path.join([Workstation.dir(identity), "credentials", Atom.to_string(harness), spec.name])

  defp write_atomic(path, body) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    _ = File.chmod(Path.dirname(dir), 0o700)
    _ = File.chmod(dir, 0o700)
    tmp = path <> ".tmp"
    File.write!(tmp, "")
    _ = File.chmod(tmp, 0o600)
    File.write!(tmp, body)
    File.rename!(tmp, path)
  end
end
