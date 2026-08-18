defmodule Loopyard.Tools.CommandGuard do
  @moduledoc """
  Allowlist validation for the two tools that splice agent-authored text into
  a host CLI (`docker compose`, `gh`). Agents control these strings; without a
  guard, `docker compose run -v /:/host …` or `gh alias set --shell …` is a
  host escape. Pure `String.t() -> :ok | {:error, String.t()}` so it is unit
  tested without Docker or GitHub.

  The design is a SUBCOMMAND allowlist plus a targeted flag denylist, because
  the meaning of a flag depends on its subcommand: `down -v` removes this
  project's own volumes (safe) while `run -v host:path` bind-mounts the host
  (escape); `logs -f` follows while `up -f` retargets the compose file. A flat
  flag denylist gets those wrong, so the checks are subcommand-aware.
  """

  # Subcommands that only ever act on the already-validated compose file /
  # this workspace's own project. `run` and `exec` are excluded on purpose —
  # both take a CLI `-v` bind mount and an arbitrary command, which is the
  # escape.
  @compose_allowed ~w(up down ps logs build restart stop start pull config
                      top images port ls kill rm create version)

  # Flags that retarget compose AWAY from the workspace's own project/file,
  # regardless of subcommand. `-p`/`--project-name` and `-f`/`--file` are
  # persistent root flags, so they take effect even after the subcommand
  # (e.g. `up -p loopyard-other`). `-f` is special-cased: for `logs` it is the
  # local `--follow` boolean, which is fine.
  @compose_deny_prefixes [
    "--project-name",
    "--project-directory",
    "--file",
    "--env-file",
    "--workdir",
    "-p",
    "-w"
  ]

  @doc "Validate a `docker compose` argument string (no leading `docker compose`)."
  @spec compose(String.t()) :: :ok | {:error, String.t()}
  def compose(command) when is_binary(command) do
    case String.split(command, ~r/\s+/, trim: true) do
      [] ->
        {:error, "Empty compose command."}

      [sub | rest] ->
        cond do
          sub not in @compose_allowed ->
            {:error,
             "docker compose `#{sub}` is not allowed. Permitted: " <>
               "#{Enum.join(@compose_allowed, ", ")}. " <>
               "`run`/`exec` are blocked (they take a host bind mount and an " <>
               "arbitrary command). Put commands in the compose file's services instead."}

          bad = Enum.find(rest, &compose_denied_flag?(&1, sub)) ->
            {:error,
             "docker compose flag `#{bad}` is not allowed — it would retarget " <>
               "the compose file or project away from this workspace, or mount the host."}

          true ->
            :ok
        end
    end
  end

  def compose(_), do: {:error, "Compose command must be a string."}

  # `-f`/`--follow` is legitimate for `logs`; every other `-f` is the root
  # `--file` flag (compose-file retarget), so it is denied outside `logs`.
  defp compose_denied_flag?(token, "logs") when token in ["-f", "--follow"], do: false
  defp compose_denied_flag?("-f", _sub), do: true

  defp compose_denied_flag?(token, _sub) do
    Enum.any?(@compose_deny_prefixes, fn p ->
      token == p or String.starts_with?(token, p <> "=") or
        (String.length(p) == 2 and String.starts_with?(token, p))
    end)
  end

  # ── gh ──────────────────────────────────────────────────────────────────

  # The RCE families: `alias` (`alias set --shell` runs through sh),
  # `extension` (installs and runs arbitrary code), and `config` (sets the
  # pager/editor, which then executes on the next gh call). Everything else —
  # read/query commands and the API — is allowed.
  @gh_denied ~w(alias extension config codespace ssh-key gpg-key)

  @doc "Validate a `gh` argument string (no leading `gh`)."
  @spec gh(String.t()) :: :ok | {:error, String.t()}
  def gh(args) when is_binary(args) do
    case OptionParser.split(args) do
      [] ->
        {:error, "No gh command given."}

      [sub | _rest] ->
        if sub in @gh_denied do
          {:error,
           "gh `#{sub}` is not allowed — it can execute arbitrary host commands " <>
             "(`alias --shell`, `extension install`, `config` pager/editor). " <>
             "Use read/query commands (org, repo, pr, issue, api, search)."}
        else
          :ok
        end
    end
  rescue
    _ -> {:error, "Could not parse gh arguments."}
  end

  def gh(_), do: {:error, "gh arguments must be a string."}
end
