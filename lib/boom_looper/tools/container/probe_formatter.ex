defmodule BoomLooper.Tools.Container.ProbeFormatter do
  @moduledoc """
  Formatting helpers for probe_http tool output.
  """

  def format_probe_success(host_port, container, path, status, body) do
    """
    HTTP #{status} from http://localhost:#{host_port}#{path}
    Mapped from container: #{container}

    Body preview:
    #{body}
    """
  end

  def format_probe_no_ports(project_name) do
    """
    No host-mapped ports found for #{project_name}-workspace-1 or #{project_name}-dev-1.

    Either the containers aren't running, or your `dev` service in
    docker-compose.yml has no `ports:` declaration. Add something like:

      dev:
        ports:
          - "3000"

    Then `docker_compose("up -d --build")`.
    """
  end

  def format_probe_no_response(attempted, path, container_states) do
    state_lines =
      container_states
      |> Enum.map(fn {name, running?} ->
        "  #{name}: #{if running?, do: "running", else: "NOT RUNNING"}"
      end)
      |> Enum.join("\n")

    # attempted entries carry the failure kind (:refused / :timeout /
    # :other) + a human detail string so the agent can tell "nothing's
    # listening" from "app is still booting."
    attempted_urls =
      attempted
      |> Enum.map(fn {container, container_port, host_port, kind, detail} ->
        "  http://localhost:#{host_port}#{path}  " <>
          "(mapped from #{container}:#{container_port}) — #{kind}: #{detail}"
      end)
      |> Enum.join("\n")

    headline =
      cond do
        Enum.all?(attempted, fn {_, _, _, k, _} -> k == :timeout end) ->
          "Every probe TIMED OUT (TCP connected but no HTTP response in 30s). The port IS bound — the app is slow to respond. This is usually a cold-start."

        Enum.all?(attempted, fn {_, _, _, k, _} -> k == :refused end) ->
          "Every probe was REFUSED (TCP not accepting). The port is not bound — likely 127.0.0.1 inside the container, or wrong port."

        true ->
          "Probes failed with mixed reasons. See per-URL detail below."
      end

    """
    #{headline}

    URLs probed (in order):
    #{attempted_urls}

    Container states:
    #{state_lines}

    Likely causes (in priority order):

    1. **The process bound to the container port is listening on 127.0.0.1.**
       Whatever listens on the container port MUST bind to 0.0.0.0. Check
       what's actually listening from INSIDE the container:

          exec command="ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null"

       If you see `127.0.0.1:<port>` next to the process, that's the bug.
       A correct bind looks like `0.0.0.0:<port>` or `*:<port>` or `:::<port>`.

       Fix depends on WHAT is listening:
         - Rails       — `bin/rails server -b 0.0.0.0` / BINDING=0.0.0.0
         - Vite        — `--host 0.0.0.0` / `server.host = true` in vite.config
         - Flask       — `flask run --host=0.0.0.0`
         - Django      — `python manage.py runserver 0.0.0.0:8000`
         - Laravel     — `php artisan serve --host=0.0.0.0`
         - php -S      — `php -S 0.0.0.0:<port>`
         - nginx       — grep the conf for `listen`; replace `127.0.0.1:` with empty or `0.0.0.0:`
         - Apache      — grep ports.conf / sites-enabled; `Listen 80` not `Listen 127.0.0.1:80`
         - Caddy       — the `:port` site block binds all interfaces; `127.0.0.1:port` binds loopback
         - Go/Express  — `app.listen(port, '0.0.0.0')` or unset the host arg

    2. **Dev server is still booting.** Big apps (Rails asset precompile,
       Next.js first build) can take 60–120s. Check `logs service="dev"`.
       If you see "Listening on 0.0.0.0" or similar, wait and retry.

    3. **Wrong port published.** Run `inspect_service name="dev"` and verify
       the published host port matches the container port the server is
       actually listening on. Mismatches happen when the Dockerfile CMD
       uses a different port than `ports:` in compose declares.
    """
  end
end
