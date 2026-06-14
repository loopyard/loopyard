defmodule LoopyardWeb.SetupController do
  @moduledoc """
  Serves the one-shot credential-transfer script for a *named* workstation. On
  your Mac:

      curl -fsS http://localhost:4000/workstation/brad/setup.sh | sh

  The script harvests whatever you're logged into (gh/fly tokens via env, plus
  file-based logins like Codex/Claude/gh) and curls them into workstation `:ws` —
  env vars via `/workstation/:ws/env`, files via `/workstation/:ws/file`. Host,
  push token, and the target workstation are baked in from the request, so it
  Just Works against this Loopyard. The Workstation page bakes your current id in.

  Gated by `PushAuth` (local = no token; remote fetch needs `?token=`).
  """
  use LoopyardWeb, :controller

  alias Loopyard.{PushToken, Workstation}
  alias LoopyardWeb.PushAuth

  def script(conn, %{"ws" => ws}) do
    cond do
      not PushAuth.authorized?(conn) ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> send_resp(403, "echo 'Loopyard: unauthorized — append ?token=<push-token>'\n")

      not Workstation.exists?(ws) ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> send_resp(404, "echo 'Loopyard: no such workstation: #{ws}'\n")

      true ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> send_resp(200, build_script(base_url(conn), PushToken.get(), ws))
    end
  end

  defp base_url(conn) do
    proto = first(conn, "x-forwarded-proto", to_string(conn.scheme))
    host = first(conn, "host", "#{conn.host}:#{conn.port}")
    "#{proto}://#{host}"
  end

  defp first(conn, header, default) do
    case get_req_header(conn, header) do
      [v | _] -> v
      _ -> default
    end
  end

  defp build_script(base, token, ws) do
    """
    #!/bin/sh
    # Loopyard — transfer your logged-in Mac credentials into workstation '#{ws}'.
    # Run on the Mac where you're logged in:  curl -fsS #{base}/workstation/#{ws}/setup.sh | sh
    L="#{base}"
    WS="#{ws}"
    AUTH="Authorization: Bearer #{token}"

    ok()   { printf "  \\033[32m✓\\033[0m %s\\n" "$1"; }
    skip() { printf "  \\033[2m–  %s (not found)\\033[0m\\n" "$1"; }

    env_push() {  # NAME VALUE
      [ -n "$2" ] || { skip "$1"; return; }
      printf '%s' "$2" | curl -fsS -T - -H "$AUTH" "$L/workstation/$WS/env/$1" >/dev/null 2>&1 \\
        && ok "$1 (env)" || skip "$1"
    }
    file_push() {  # LOCAL REMOTE
      [ -f "$1" ] || { skip "$2"; return; }
      curl -fsS -T - -H "$AUTH" "$L/workstation/$WS/file/$2" < "$1" >/dev/null 2>&1 \\
        && ok "$2 (file)" || skip "$2"
    }

    echo "Transferring credentials → $L (workstation: $WS)"

    # token-based (env vars — Restart to apply)
    command -v gh  >/dev/null 2>&1 && env_push GITHUB_TOKEN     "$(gh auth token 2>/dev/null)"
    command -v fly >/dev/null 2>&1 && env_push FLY_ACCESS_TOKEN "$(fly auth token 2>/dev/null)"

    # file-based logins (land in $HOME — live, no restart)
    file_push "$HOME/.codex/auth.json"          ".codex/auth.json"
    file_push "$HOME/.claude/.credentials.json" ".claude/.credentials.json"
    file_push "$HOME/.config/gh/hosts.yml"      ".config/gh/hosts.yml"
    file_push "$HOME/.netrc"                    ".netrc"

    echo "Done. Env vars need a workstation Restart; files are already live."
    """
  end
end
