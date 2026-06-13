defmodule Loopyard.Workstation.OpenBridge do
  @moduledoc """
  Bridges a container's "open a URL in the browser" mechanism to the operator's
  actual browser.

  Headless containers can't open a browser, so device-flow logins (`gh auth
  login`, `claude login`, `fly auth login`) call `$BROWSER`/`xdg-open <url>` and
  fail. We replace that with a shim (baked into the image) that POSTs the URL to
  Loopyard's `/internal/open-url` endpoint; Loopyard broadcasts it to the
  Workstation page, which pops a one-tap **Open** button. No copy/paste.

  **Security.** The endpoint is reachable over the public quick-tunnel, so it's
  gated by the general `Loopyard.Token` — and specifically the `open_url` grant
  on it. The container holds the token (written to `/etc/loopyard-open.env`); the
  endpoint checks the grant with a constant-time compare. Worst case for a
  forged-but-tokenless request: nothing (rejected). The token lives only on the
  host (mode 0600) and in container env — never sent to the browser. This module
  owns only the bridge *mechanics*; the secret + grants live in `Loopyard.Token`.
  """
  alias Loopyard.{Docker, Token}

  @env_path "/etc/loopyard-open.env"

  @doc "The endpoint a container curls — host-reachable from inside Docker."
  @spec endpoint_url() :: String.t()
  def endpoint_url do
    port = LoopyardWeb.Endpoint.config(:http)[:port] || 4000
    "http://host.docker.internal:#{port}/internal/open-url"
  end

  @doc """
  `docker run` env args that hand a container the bridge config. New containers
  get the bridge via these; see `install/1` for patching an already-running one.
  """
  @spec env_args() :: [String.t()]
  def env_args do
    [
      "-e",
      "LOOPYARD_OPEN_URL=#{endpoint_url()}",
      "-e",
      "#{Token.env_var()}=#{Token.secret()}"
    ]
  end

  @doc """
  Make an already-running container's browser-open route to us, with NO recreate:
  push the current shim to `/usr/local/bin/loopyard-open` (+ the `xdg-open`
  symlink) and write `/etc/loopyard-open.env` (endpoint + token). Self-heals
  containers built from an image that predates the bridge. Best-effort.
  """
  @spec install(String.t()) :: :ok
  def install(container) do
    env = """
    LOOPYARD_OPEN_URL=#{endpoint_url()}
    #{Token.env_var()}=#{Token.secret()}
    """

    _ = Docker.exec_in(container, "cat > #{@env_path} <<'LOOPYARD_EOF'\n#{env}LOOPYARD_EOF")

    shim_path = Application.app_dir(:loopyard, "priv/workspace-base/loopyard-open")

    case File.read(shim_path) do
      {:ok, shim} ->
        _ =
          Docker.exec_in(
            container,
            "cat > /usr/local/bin/loopyard-open <<'LOOPYARD_EOF'\n#{shim}LOOPYARD_EOF\n" <>
              "chmod +x /usr/local/bin/loopyard-open && " <>
              "ln -sf /usr/local/bin/loopyard-open /usr/local/bin/xdg-open"
          )

      _ ->
        :ok
    end

    :ok
  end
end
