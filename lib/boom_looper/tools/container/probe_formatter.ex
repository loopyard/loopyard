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

    attempted_urls =
      attempted
      |> Enum.map(fn {container, container_port, host_port} ->
        "  http://localhost:#{host_port}#{path}  (mapped from #{container}:#{container_port})"
      end)
      |> Enum.join("\n")

    """
    Connection refused on every host port I tried.

    URLs probed (in order):
    #{attempted_urls}

    Container states:
    #{state_lines}

    Likely causes:
    - Your dev server is bound to 127.0.0.1 inside the container (Rails default,
      Vite default, Flask default). Bind to 0.0.0.0:
        Rails:    `bin/rails server -b 0.0.0.0` or set BINDING=0.0.0.0
        Vite:     `--host 0.0.0.0` or `server.host = true`
        Flask:    `flask run --host=0.0.0.0`
        Django:   `python manage.py runserver 0.0.0.0:8000`
        Next.js:  binds to 0.0.0.0 by default — should be fine
    - Dev server is still booting. Check `logs service="dev"` and wait, then retry.
    - Wrong port: run `inspect_service name="dev"` to see what's actually listening.
    """
  end
end
