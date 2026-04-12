defmodule BoomLooper.Tools.Container do
  @moduledoc """
  MCP tools for interacting with Docker containers.

  Workspace agents exec into the workspace container (always alive, sleep infinity).
  Service agents exec into their service's container (dev, postgres, etc.).
  """
  use ClaudeCode.MCP.Server, name: "boom-looper-container"

  alias BoomLooper.Docker
  alias BoomLooper.Workspace.ServiceManager

  # --- Path validation ---

  @doc """
  Validate that a file path stays within /workspace.
  Rejects path traversal (../), absolute paths outside /workspace,
  and null bytes. Returns {:ok, normalized} or {:error, reason}.
  """
  def validate_workspace_path(path) when is_binary(path) do
    cond do
      String.contains?(path, <<0>>) ->
        {:error, "Path contains null bytes"}

      true ->
        # Normalize: relative paths resolve against /workspace,
        # absolute paths are taken as-is
        normalized = Path.expand(path, "/workspace")

        if String.starts_with?(normalized, "/workspace/") or normalized == "/workspace" do
          {:ok, normalized}
        else
          {:error, "Path must be within /workspace: #{path}"}
        end
    end
  end

  def validate_workspace_path(_), do: {:error, "Path must be a string"}

  # --- Public API ---

  def do_exec(agent_id, command, opts \\ %{}) do
    case resolve_container(agent_id) do
      {:ok, container} ->
        exec_opts = []
        exec_opts = if Map.has_key?(opts, :workdir), do: Keyword.put(exec_opts, :workdir, opts.workdir), else: exec_opts
        # Tool accepts seconds, Docker.exec_in expects milliseconds
        exec_opts = if Map.has_key?(opts, :timeout), do: Keyword.put(exec_opts, :timeout, opts.timeout * 1_000), else: exec_opts

        Docker.exec_in(container, command, exec_opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def do_logs(agent_id, opts \\ %{}) do
    service = Map.get(opts, :service)
    lines = Map.get(opts, :lines, 200)

    if service do
      # Logs for a specific service container
      case resolve_service_container(agent_id, service) do
        {:ok, container} -> Docker.container_logs(container, tail: lines)
        {:error, reason} -> {:error, reason}
      end
    else
      # Logs for the agent's own container
      case resolve_container(agent_id) do
        {:ok, container} -> Docker.container_logs(container, tail: lines)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def do_ports(agent_id) do
    case resolve_container(agent_id) do
      {:ok, container} ->
        Docker.exec_in(container, """
        echo "=== Listening ports ==="
        ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo "[not available]"
        """)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def do_inspect(agent_id) do
    case resolve_container(agent_id) do
      {:ok, container} ->
        checks = [
          {"Running processes", "ps aux --no-headers 2>/dev/null || ps 2>/dev/null"},
          {"Listening ports", "ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo '[ss/netstat not available]'"},
          {"Installed languages", "for cmd in node python3 ruby go java elixir; do which $cmd 2>/dev/null && $cmd --version 2>&1 | head -1; done"},
          {"Installed databases", "for cmd in psql mysql redis-cli mongosh sqlite3; do which $cmd 2>/dev/null && echo \"  $cmd available\"; done"},
          {"Installed tools", "for cmd in git curl wget make gcc npm yarn pip cargo mix bundle; do which $cmd 2>/dev/null; done"},
          {"Disk usage", "df -h /workspace 2>/dev/null | tail -1"}
        ]

        results =
          Enum.map(checks, fn {label, cmd} ->
            output = case Docker.exec_in(container, cmd) do
              {:ok, out} -> String.trim(out)
              {:error, _} -> "[error]"
            end
            "## #{label}\n#{output}"
          end)

        {:ok, Enum.join(results, "\n\n")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Tool definitions ---

  tool :exec, "Run a shell command inside the container. Use timeout for long-running commands (dependency installs, builds, etc.)." do
    field :agent_id, :string, required: true
    field :command, :string, required: true
    field :workdir, :string, required: false
    field :timeout, :integer, required: false, description: "Max seconds to run (default: 120)"

    def execute(%{agent_id: agent_id, command: command} = params) do
      BoomLooper.Tools.Container.do_exec(agent_id, command, params)
    end
  end

  tool :exec_stream, "Run a long-running command with streaming output (e.g. ping, tail -f, watch). Output streams into the chat. The command runs in the background — you can keep working." do
    field :agent_id, :string, required: true
    field :command, :string, required: true
    field :timeout, :integer, required: false, description: "Max seconds to run (default: 30)"

    def execute(%{agent_id: agent_id, command: command} = params) do
      BoomLooper.Tools.Container.do_exec_stream(agent_id, command, Map.get(params, :timeout, 30))
    end
  end

  tool :logs, "View container logs (works on running AND stopped/crashed containers). Pass 'service' to see a specific service's logs (e.g. 'dev', 'postgres'). Use service_containers first to see what's available." do
    field :agent_id, :string, required: true
    field :service, :string, required: false, description: "Service name to get logs for (e.g. 'dev', 'postgres', 'redis')"
    field :lines, :integer, required: false

    def execute(%{agent_id: agent_id} = params) do
      BoomLooper.Tools.Container.do_logs(agent_id, params)
    end
  end

  tool :inspect_env, "Inspect the container environment: installed languages, databases, tools, running processes, listening ports" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Container.do_inspect(agent_id)
    end
  end

  tool :service_containers, "List all containers for this workspace. Call ONCE after rebuild completes. Do NOT poll — if containers aren't up, read logs instead." do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Container.do_service_containers(agent_id)
    end
  end

  tool :ports, "Show all listening ports in the container" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Container.do_ports(agent_id)
    end
  end

  tool :write_file, "Write a file to the workspace. Use for Dockerfile, docker-compose.yml, config files, etc. Path is relative to /workspace." do
    field :agent_id, :string, required: true
    field :path, :string, required: true, description: "File path relative to /workspace (e.g. '.boomlooper/workspace/Dockerfile' or '.boomlooper/workspace/docker-compose.yml')"
    field :content, :string, required: true, description: "File content"

    def execute(%{agent_id: agent_id, path: path, content: content}) do
      BoomLooper.Tools.Container.do_write_file(agent_id, path, content)
    end
  end

  tool :read_file, "Read a file from the workspace. Path is relative to /workspace." do
    field :agent_id, :string, required: true
    field :path, :string, required: true, description: "File path relative to /workspace"

    def execute(%{agent_id: agent_id, path: path}) do
      BoomLooper.Tools.Container.do_read_file(agent_id, path)
    end
  end

  tool :edit, "Atomic find/replace in a workspace file. PREFER THIS over read_file+write_file for changes — it's atomic, cheaper in tokens (just the diff, not the whole file twice), and gives clear errors if old_string isn't unique. Use replace_all for refactors that touch every occurrence." do
    field :agent_id, :string, required: true
    field :path, :string, required: true, description: "File path relative to /workspace (e.g. 'app/javascript/dashboard/i18n/locale/en/login.json')"
    field :old_string, :string, required: true, description: "Exact text to replace. Must be unique in the file unless replace_all=true. Multi-line strings work — pass with literal newlines."
    field :new_string, :string, required: true, description: "Replacement text. Pass empty string to delete."
    field :replace_all, :boolean, required: false, description: "Replace every occurrence (default: false — fails if old_string appears more than once)"

    def execute(%{agent_id: agent_id, path: path, old_string: old_string, new_string: new_string} = params) do
      BoomLooper.Tools.Container.do_edit(agent_id, path, old_string, new_string, params)
    end
  end

  tool :multi_edit, "Apply many edits to one file as a single atomic read-modify-write. Cheaper than calling `edit` N times. Edits run in order against the running result, so a later edit can match text produced by an earlier one. If ANY edit fails, the file is not written." do
    field :agent_id, :string, required: true
    field :path, :string, required: true, description: "File path relative to /workspace"
    field :edits, :string, required: true, description: ~s|JSON array of edits, e.g. '[{"old_string": "foo", "new_string": "bar"}, {"old_string": "baz", "new_string": "qux", "replace_all": true}]'|

    def execute(%{agent_id: agent_id, path: path, edits: edits}) do
      case Jason.decode(to_string(edits)) do
        {:ok, list} when is_list(list) ->
          BoomLooper.Tools.Container.do_multi_edit(agent_id, path, list)

        {:ok, _} ->
          {:error, "edits must be a JSON array"}

        {:error, reason} ->
          {:error, "edits is not valid JSON: #{inspect(reason)}"}
      end
    end
  end

  tool :grep, "Recursive content search inside the workspace. Returns structured matches (file:line: content). PREFER THIS over `exec(\"grep -rn ...\")`. Excludes .git/node_modules/vendor/_build/deps/.next/dist/target/.venv/__pycache__ automatically." do
    field :agent_id, :string, required: true
    field :pattern, :string, required: true, description: "Text to search for. Fixed string by default — pass regex=true for extended regex (grep -E)."
    field :path, :string, required: false, description: "Subdirectory under /workspace to search (default: whole workspace)"
    field :include, :string, required: false, description: "File pattern to filter, e.g. '*.json' or '*.{ts,vue}'"
    field :regex, :boolean, required: false, description: "Treat pattern as extended regex (default: false — fixed string)"
    field :output_mode, :string, required: false, description: "'lines' (default — file:line: content) or 'files' (just unique file paths)"
    field :head_limit, :integer, required: false, description: "Max matches to return (default: 200)"

    def execute(%{agent_id: agent_id, pattern: pattern} = params) do
      BoomLooper.Tools.Container.do_grep(agent_id, pattern, params)
    end
  end

  tool :glob, "Find files in the workspace by glob pattern (e.g. '*.json', '**/*.ts', 'app/**/*.vue'). Returns paths relative to /workspace. PREFER THIS over `exec(\"find ...\")`. Excludes the same junk dirs as `grep`." do
    field :agent_id, :string, required: true
    field :pattern, :string, required: true, description: "Glob pattern. '*' matches one segment, '**' matches any depth. Examples: '*.json', '**/*.ts', 'app/**/*.vue'"
    field :path, :string, required: false, description: "Subdirectory under /workspace to search from (default: whole workspace)"
    field :head_limit, :integer, required: false, description: "Max files to return (default: 200)"

    def execute(%{agent_id: agent_id, pattern: pattern} = params) do
      BoomLooper.Tools.Container.do_glob(agent_id, pattern, params)
    end
  end

  tool :probe_http, "Probe an HTTP endpoint from the HOST'S perspective — the same vantage point the eval runner uses. ALWAYS use this to verify the dev server is reachable. Without args, finds the workspace's published host port and probes /. Pass `port` to override which container port to look up, or `path` to hit /up, /health, etc. The response includes the exact URL probed, status code, body preview, and (on failure) a per-stack diagnosis of likely causes." do
    field :agent_id, :string, required: true
    field :port, :integer, required: false, description: "Container port to look up (e.g. 3000). Default: probe whatever's published on workspace or dev container."
    field :path, :string, required: false, description: "Request path. Default: '/'. Common alternatives: '/up' (Rails), '/health', '/healthz'."

    def execute(%{agent_id: agent_id} = params) do
      BoomLooper.Tools.Container.do_probe_http(agent_id, params)
    end
  end

  tool :tree, "Print a directory tree from inside the workspace. ONE call gives spatial awareness of the whole project — file types, sizes, hierarchy. PREFER THIS over `exec(\"ls -la\")` or `exec(\"find ...\")` for discovery. Auto-excludes .git, node_modules, vendor/bundle, _build, deps, .next, dist, target, .venv, __pycache__." do
    field :agent_id, :string, required: true
    field :path, :string, required: false, description: "Subdirectory under /workspace (default: whole workspace)"
    field :depth, :integer, required: false, description: "Max depth to descend (default: 3, max: 8)"
    field :max_entries, :integer, required: false, description: "Max entries to print (default: 200)"

    def execute(%{agent_id: agent_id} = params) do
      BoomLooper.Tools.Container.do_tree(agent_id, params)
    end
  end

  tool :inspect_service, "Get a complete snapshot of one service in ONE call: container state, exit code, host/container port mapping, last 50 log lines, and an extracted error summary. PREFER THIS over fanning out to `docker_compose ps` + `logs` + `ports` + `docker port` separately." do
    field :agent_id, :string, required: true
    field :name, :string, required: true, description: "Service name from docker-compose.yml (e.g. 'dev', 'postgres', 'redis')"

    def execute(%{agent_id: agent_id, name: name}) do
      BoomLooper.Tools.Container.do_inspect_service(agent_id, name)
    end
  end

  tool :read_files, "Read several files in ONE round trip. PREFER THIS over multiple `read_file` calls during discovery (e.g. reading Gemfile + package.json + README + Procfile.dev at once). Files that don't exist show up as `(error: ...)` so partial failures don't lose the rest." do
    field :agent_id, :string, required: true
    field :paths, :string, required: true, description: ~s|JSON array of file paths relative to /workspace, e.g. '["Gemfile", "package.json", "README.md"]'|

    def execute(%{agent_id: agent_id, paths: paths}) do
      case Jason.decode(to_string(paths)) do
        {:ok, list} when is_list(list) ->
          BoomLooper.Tools.Container.do_read_files(agent_id, list)

        {:ok, _} ->
          {:error, "paths must be a JSON array of strings"}

        {:error, reason} ->
          {:error, "paths is not valid JSON: #{inspect(reason)}"}
      end
    end
  end

  tool :docker, "Run any Docker CLI command. Use for inspecting containers, volumes, images, networks, etc." do
    field :agent_id, :string, required: true
    field :command, :string, required: true, description: "Docker command (e.g. 'ps -a', 'volume ls', 'inspect mycontainer', 'images')"
    field :timeout, :integer, required: false, description: "Max seconds to run (default: 30)"

    def execute(%{agent_id: _agent_id, command: command} = params) do
      BoomLooper.Tools.Container.do_docker(command, Map.get(params, :timeout, 30))
    end
  end

  tool :docker_compose, "Run any docker compose command. Compose file is at .boomlooper/workspace/docker-compose.yml" do
    field :agent_id, :string, required: true
    field :command, :string, required: true, description: "Compose command (e.g. 'up -d --build', 'down', 'ps', 'logs dev', 'restart dev')"
    field :timeout, :integer, required: false, description: "Max seconds to run (default: 300 for builds)"

    def execute(%{agent_id: agent_id, command: command} = params) do
      BoomLooper.Tools.Container.do_docker_compose(agent_id, command, Map.get(params, :timeout, 300))
    end
  end

  tool :workspace_info, "Get workspace metadata: ID, volume name, paths, container names" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Container.do_workspace_info(agent_id)
    end
  end

  tool :volumes, "List and inspect Docker volumes for this workspace" do
    field :agent_id, :string, required: true
    field :action, :string, required: false, description: "Action: 'list' (default), 'ls <volume> [path]', 'info <volume>'"

    def execute(%{agent_id: agent_id} = params) do
      BoomLooper.Tools.Container.do_volumes(agent_id, Map.get(params, :action, "list"))
    end
  end

  def do_write_file(agent_id, path, content) do
    with {:ok, _} <- validate_workspace_path(path) do
      case BoomLooper.ChatAgent.get_state(agent_id) do
        %{workspace_id: workspace_id} when is_binary(workspace_id) ->
          volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)

          # Substitute variables in compose files
          content = if String.ends_with?(path, "docker-compose.yml") do
            content
            |> String.replace("${CODE_VOLUME}", volume_name)
            |> String.replace("${WORKSPACE_ID}", workspace_id)
          else
            content
          end

          # Use VolumeManager - handles running container vs temporary container
          case BoomLooper.VolumeManager.write_file(volume_name, path, content) do
            :ok -> {:ok, "Wrote #{byte_size(content)} bytes to #{path}"}
            {:error, reason} -> {:error, "Failed to write file: #{reason}"}
          end

        _ ->
          {:error, "Agent #{agent_id} has no workspace"}
      end
    end
  end

  def do_read_file(agent_id, path) do
    with {:ok, _} <- validate_workspace_path(path) do
      case BoomLooper.ChatAgent.get_state(agent_id) do
        %{workspace_id: workspace_id} when is_binary(workspace_id) ->
          volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)
          BoomLooper.VolumeManager.read_file(volume_name, path)

        _ ->
          {:error, "Agent #{agent_id} has no workspace"}
      end
    end
  end

  @doc """
  Atomic find/replace inside a workspace file. Mirrors Claude Code's
  native `Edit` tool but operates on the workspace volume via the
  same in-process VolumeManager pipeline as `read_file`/`write_file`.

  Handled in Elixir, NOT shell — no quoting/escaping pitfalls. Multi-
  line `old_string` works. The agent never sees the full file content
  in its context, only the diff, so this is dramatically cheaper in
  tokens than read+modify+write.
  """
  def do_edit(agent_id, path, old_string, new_string, opts \\ %{}) do
    replace_all? = Map.get(opts, :replace_all, false)

    with {:ok, _} <- validate_workspace_path(path) do
      cond do
        old_string == "" ->
          {:error, "old_string must not be empty (use write_file to create a new file)"}

        old_string == new_string ->
          {:error, "old_string and new_string are identical — nothing to change"}

        true ->
          with {:ok, workspace_id} <- agent_workspace_id(agent_id) do
          volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)

          case BoomLooper.VolumeManager.read_file(volume_name, path) do
            {:ok, content} ->
              do_edit_in_memory(volume_name, path, content, old_string, new_string, replace_all?)

            {:error, :not_found} ->
              {:error, "File not found: #{path}"}

            {:error, reason} ->
              {:error, "Failed to read #{path}: #{inspect(reason)}"}
          end
        end
      end
    end
  end

  defp do_edit_in_memory(volume_name, path, content, old, new, replace_all?) do
    occurrences =
      content
      |> String.split(old)
      |> length()
      |> Kernel.-(1)

    cond do
      occurrences == 0 ->
        {:error,
         "old_string not found in #{path}. The file does NOT contain the literal text you " <>
           "passed. Use `grep` to find the actual text in context, then retry with the exact match."}

      occurrences > 1 and not replace_all? ->
        {:error,
         "old_string appears #{occurrences} times in #{path}. Either pass replace_all: true to " <>
           "change all of them, or expand old_string with surrounding context until it's unique."}

      true ->
        new_content =
          if replace_all? do
            String.replace(content, old, new, global: true)
          else
            String.replace(content, old, new, global: false)
          end

        case BoomLooper.VolumeManager.write_file(volume_name, path, new_content) do
          :ok ->
            replaced = if replace_all?, do: occurrences, else: 1
            {:ok, "Replaced #{replaced} occurrence(s) in #{path} (#{byte_size(new_content)} bytes)"}

          {:error, reason} ->
            {:error, "Failed to write #{path}: #{inspect(reason)}"}
        end
    end
  end

  @doc """
  Apply many edits to a single file as one atomic read-modify-write.
  Cheaper than calling `edit` N times because there's only one round
  trip to the volume. Mirrors Claude Code's native `MultiEdit`.

  `edits` is a list of `%{"old_string" => ..., "new_string" => ...,
  "replace_all" => bool?}` maps.

  Edits are applied in order. If any one edit fails (string not found,
  ambiguous match), the WHOLE operation aborts and the file is not
  written — atomicity guarantee.
  """
  def do_multi_edit(agent_id, path, edits) when is_list(edits) do
    with {:ok, _} <- validate_workspace_path(path) do
      cond do
        edits == [] ->
          {:error, "edits list must not be empty"}

        true ->
          with {:ok, workspace_id} <- agent_workspace_id(agent_id) do
            volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)

            case BoomLooper.VolumeManager.read_file(volume_name, path) do
              {:ok, content} ->
                apply_multi_edit(volume_name, path, content, edits)

              {:error, :not_found} ->
                {:error, "File not found: #{path}"}

              {:error, reason} ->
                {:error, "Failed to read #{path}: #{inspect(reason)}"}
            end
          end
      end
    end
  end

  defp apply_multi_edit(volume_name, path, content, edits) do
    Enum.reduce_while(edits, {:ok, content, 0}, fn edit, {:ok, current, idx} ->
      old = edit["old_string"] || edit[:old_string]
      new = edit["new_string"] || edit[:new_string]
      replace_all? = edit["replace_all"] || edit[:replace_all] || false

      cond do
        is_nil(old) or old == "" ->
          {:halt, {:error, "edit ##{idx + 1}: old_string is missing or empty"}}

        is_nil(new) ->
          {:halt, {:error, "edit ##{idx + 1}: new_string is missing"}}

        true ->
          occurrences = (current |> String.split(old) |> length()) - 1

          cond do
            occurrences == 0 ->
              {:halt,
               {:error, "edit ##{idx + 1}: old_string not found (after #{idx} prior edits applied)"}}

            occurrences > 1 and not replace_all? ->
              {:halt,
               {:error,
                "edit ##{idx + 1}: old_string appears #{occurrences} times — pass replace_all: true or expand the context"}}

            true ->
              new_content = String.replace(current, old, new, global: replace_all?)
              {:cont, {:ok, new_content, idx + 1}}
          end
      end
    end)
    |> case do
      {:ok, new_content, count} ->
        case BoomLooper.VolumeManager.write_file(volume_name, path, new_content) do
          :ok ->
            {:ok, "Applied #{count} edit(s) to #{path} (#{byte_size(new_content)} bytes)"}

          {:error, reason} ->
            {:error, "Failed to write #{path}: #{inspect(reason)}"}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Recursive content search inside the workspace, mirroring Claude
  Code's native `Grep` tool. Returns structured results, not parsed
  shell output.

  - `pattern` is a fixed string by default. Pass `regex: true` for
    extended regex (`grep -E`).
  - `path` is relative to /workspace. Default is the whole workspace.
  - `include` is a glob like `*.{js,ts}` to filter files.
  - `output_mode` is `"lines"` (default — `[{file, line, content}, …]`)
    or `"files"` (just unique file paths).

  Skips `.git`, `node_modules`, `vendor/bundle`, `_build`, `deps`,
  `.next`, `dist`, and similar large junk dirs by default — they're
  almost never what an agent is searching for and they balloon
  output.
  """
  def do_grep(agent_id, pattern, opts \\ %{}) do
    path = Map.get(opts, :path, ".") |> normalize_search_path()
    include = Map.get(opts, :include)
    regex? = Map.get(opts, :regex, false)
    output_mode = Map.get(opts, :output_mode, "lines")
    head_limit = Map.get(opts, :head_limit, 200)

    with {:ok, _} <- validate_workspace_path(path) do
      cond do
        pattern == "" ->
          {:error, "pattern must not be empty"}

        true ->
          do_grep_in_container(agent_id, pattern, path, include, regex?, output_mode, head_limit)
      end
    end
  end

  defp do_grep_in_container(agent_id, pattern, path, include, regex?, output_mode, head_limit) do
    case resolve_container(agent_id) do
      {:ok, container} ->
        flags = ["-rn", "--color=never"]
        flags = if regex?, do: flags ++ ["-E"], else: flags ++ ["-F"]
        flags = flags ++ ["--exclude-dir=.git", "--exclude-dir=node_modules",
                          "--exclude-dir=vendor", "--exclude-dir=_build",
                          "--exclude-dir=deps", "--exclude-dir=.next",
                          "--exclude-dir=dist", "--exclude-dir=target",
                          "--exclude-dir=.venv", "--exclude-dir=__pycache__"]

        flags = if include, do: flags ++ ["--include=#{include}"], else: flags

        full_path = Path.join("/workspace", path)
        cmd = "grep #{Enum.join(flags, " ")} #{shell_quote(pattern)} #{shell_quote(full_path)} 2>/dev/null | head -n #{head_limit}"

        case Docker.exec_in(container, cmd, timeout: 30_000) do
          {:ok, ""} ->
            {:ok, "No matches for #{inspect(pattern)} in #{path}"}

          {:ok, output} ->
            format_grep_output(output, output_mode, head_limit)

          {:error, reason} ->
            {:error, "grep failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_grep_output(output, "files", _head_limit) do
    files =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 3) do
          [file, _line, _content] -> Path.relative_to(file, "/workspace")
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case files do
      [] -> {:ok, "No files matched."}
      _ -> {:ok, Enum.join(files, "\n")}
    end
  end

  defp format_grep_output(output, _lines, head_limit) do
    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 3) do
          [file, lno, content] ->
            "#{Path.relative_to(file, "/workspace")}:#{lno}: #{content}"

          _ ->
            line
        end
      end)

    truncated = if length(lines) >= head_limit, do: "\n... (truncated to #{head_limit} matches)", else: ""
    {:ok, Enum.join(lines, "\n") <> truncated}
  end

  @doc """
  Find files by name pattern inside the workspace, mirroring Claude
  Code's native `Glob` tool. Returns a list of matching paths,
  relative to /workspace.

  - `pattern` is a glob like `*.json`, `**/*.ts`, or `app/**/*.vue`.
    `**` matches any number of directories.
  - `path` is the root to search from (default: workspace root).

  Skips the same junk dirs as `grep` (`.git`, `node_modules`, etc.).
  """
  def do_glob(agent_id, pattern, opts \\ %{}) do
    path = Map.get(opts, :path, ".") |> normalize_search_path()
    head_limit = Map.get(opts, :head_limit, 200)

    with {:ok, _} <- validate_workspace_path(path) do
      cond do
        pattern == "" ->
          {:error, "pattern must not be empty"}

        true ->
          do_glob_in_container(agent_id, pattern, path, head_limit)
      end
    end
  end

  defp do_glob_in_container(agent_id, pattern, path, head_limit) do
    case resolve_container(agent_id) do
      {:ok, container} ->
        full_path = Path.join("/workspace", path)
        find_args = glob_to_find_args(pattern)

        cmd =
          "find #{shell_quote(full_path)} -type f " <>
            "-not -path '*/.git/*' -not -path '*/node_modules/*' " <>
            "-not -path '*/vendor/bundle/*' -not -path '*/_build/*' " <>
            "-not -path '*/deps/*' -not -path '*/.next/*' " <>
            "-not -path '*/dist/*' -not -path '*/target/*' " <>
            "-not -path '*/.venv/*' -not -path '*/__pycache__/*' " <>
            "#{find_args} 2>/dev/null | head -n #{head_limit}"

        case Docker.exec_in(container, cmd, timeout: 30_000) do
          {:ok, ""} ->
            {:ok, "No files matched #{inspect(pattern)}"}

          {:ok, output} ->
            relative =
              output
              |> String.split("\n", trim: true)
              |> Enum.map(&Path.relative_to(&1, "/workspace"))

            truncated = if length(relative) >= head_limit, do: "\n... (truncated to #{head_limit} files)", else: ""
            {:ok, Enum.join(relative, "\n") <> truncated}

          {:error, reason} ->
            {:error, "find failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Translate a glob pattern into find arguments. Handles:
  #   *.ext       → -name '*.ext'
  #   **/*.ext    → -name '*.ext'        (find is recursive by default with -type f)
  #   subdir/**/*.ext → -path '*/subdir/*' -name '*.ext'
  defp glob_to_find_args(pattern) do
    cond do
      String.starts_with?(pattern, "**/") ->
        # `**/foo/bar.ext` — match `bar.ext` at any depth, with the
        # path containing `foo/bar.ext`. `-name` only matches basenames
        # (no slashes), so when the leaf has slashes we use `-path`.
        leaf = String.replace_prefix(pattern, "**/", "")

        if String.contains?(leaf, "/") do
          "-path #{shell_quote("*/#{leaf}")}"
        else
          "-name #{shell_quote(leaf)}"
        end

      String.contains?(pattern, "/**") ->
        # e.g. "app/**/*.vue" → -path '*/app/*' -name '*.vue'
        case String.split(pattern, "/**") do
          [prefix, "/" <> leaf] when leaf != "" ->
            if String.contains?(leaf, "/") do
              "-path #{shell_quote("*/#{prefix}/*/#{leaf}")}"
            else
              "-path #{shell_quote("*/#{prefix}/*")} -name #{shell_quote(leaf)}"
            end

          [prefix, ""] ->
            "-path #{shell_quote("*/#{prefix}/*")}"

          _ ->
            "-name #{shell_quote(pattern)}"
        end

      String.contains?(pattern, "/") ->
        "-path #{shell_quote("*/#{pattern}")}"

      true ->
        "-name #{shell_quote(pattern)}"
    end
  end

  defp normalize_search_path("."), do: "."
  defp normalize_search_path(""), do: "."
  defp normalize_search_path(path) when is_binary(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_leading("./")
  end

  defp shell_quote(s) when is_binary(s) do
    # Single-quote and escape any embedded single quotes.
    # Keeps shell metacharacters in the pattern from being interpreted.
    "'" <> String.replace(s, "'", "'\"'\"'") <> "'"
  end

  defp agent_workspace_id(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: wid} when is_binary(wid) -> {:ok, wid}
      _ -> {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  @doc """
  Probe an HTTP endpoint from the **host's** perspective — the same
  vantage point as the eval runner. Mirrors the runner's probe_web_service
  logic so the agent can self-verify and see exactly what the runner sees.

  Without arguments, finds the workspace's published host port (workspace
  container first, then dev container) and probes `/`. Pass `port` to
  override which container port to look up, or `path` to hit a specific
  endpoint like `/up` or `/health`.

  Returns a structured report including the URL probed, status code,
  body preview, and (on failure) a diagnosis of likely causes — so the
  agent doesn't have to guess whether its own `curl dev:3000` from inside
  the container disagreeing with the runner means the app is bound to
  127.0.0.1 vs the published port is wrong vs the container is not yet
  ready.
  """
  def do_probe_http(agent_id, opts \\ %{}) do
    container_port = Map.get(opts, :port)
    path = Map.get(opts, :path, "/")

    with {:ok, workspace_id} <- agent_workspace_id(agent_id) do
      project_name = BoomLooper.Compose.project_name(workspace_id)
      candidates = discover_dev_host_ports(project_name, container_port)

      case try_probe_candidates(candidates, path, project_name) do
        {:ok, host_port, status, body, container_name} ->
          {:ok, format_probe_success(host_port, container_name, path, status, body)}

        {:error, :no_ports} ->
          {:ok, format_probe_no_ports(project_name)}

        {:error, {:no_response, attempted, container_states}} ->
          {:ok, format_probe_no_response(attempted, path, container_states)}
      end
    end
  end

  # Find published host ports for the workspace's web-serving containers,
  # in priority order: workspace container first, then dev container.
  defp discover_dev_host_ports(project_name, nil) do
    workspace_name = "#{project_name}-workspace-1"
    dev_name = "#{project_name}-dev-1"

    for name <- [workspace_name, dev_name],
        container_running?(name),
        {container_port, host_port} <- BoomLooper.Docker.container_ports(name) do
      {name, container_port, host_port}
    end
  end

  defp discover_dev_host_ports(project_name, container_port) do
    target = to_string(container_port)
    workspace_name = "#{project_name}-workspace-1"
    dev_name = "#{project_name}-dev-1"

    for name <- [workspace_name, dev_name],
        container_running?(name),
        {cport, host_port} <- BoomLooper.Docker.container_ports(name),
        cport == target do
      {name, cport, host_port}
    end
  end

  defp try_probe_candidates([], _path, _project_name), do: {:error, :no_ports}

  defp try_probe_candidates(candidates, path, project_name) do
    {results, _} =
      Enum.reduce_while(candidates, {[], nil}, fn {container, container_port, host_port}, {acc, _} ->
        url = "http://localhost:#{host_port}#{path}"

        case http_get(url) do
          {:ok, status, body} ->
            {:halt, {{:found, host_port, container, status, body}, nil}}

          :error ->
            {:cont, {[{container, container_port, host_port} | acc], nil}}
        end
      end)

    case results do
      {:found, host_port, container, status, body} ->
        {:ok, host_port, status, body, container}

      attempted when is_list(attempted) ->
        states =
          for {container, _, _} <- Enum.uniq_by(attempted, fn {c, _, _} -> c end), into: %{} do
            {container, container_running?(container)}
          end

        _ = project_name
        {:error, {:no_response, Enum.reverse(attempted), states}}
    end
  end

  defp container_running?(name), do: BoomLooper.Docker.container_running?(name)

  defp http_get(url) do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 5_000, connect_timeout: 3_000], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} ->
        {:ok, status, String.slice(to_string(body), 0..600)}

      _ ->
        :error
    end
  end

  defp format_probe_success(host_port, container, path, status, body) do
    """
    HTTP #{status} from http://localhost:#{host_port}#{path}
    Mapped from container: #{container}

    Body preview:
    #{body}
    """
  end

  defp format_probe_no_ports(project_name) do
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

  defp format_probe_no_response(attempted, path, container_states) do
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

  @doc """
  Print a directory tree from inside the workspace container.

  One call → spatial awareness. Replaces the typical sequence of
  `exec("ls -la /workspace")` + `exec("find /workspace -maxdepth 2 ...")`
  + manual stitching. The agent gets file types, sizes, and a real
  hierarchy in one structured response.

  Defaults to the workspace root, depth 3, capped at 200 entries.
  Auto-excludes `.git`, `node_modules`, `vendor/bundle`, `_build`,
  `deps`, `.next`, `dist`, `target`, `.venv`, `__pycache__`.
  """
  def do_tree(agent_id, opts \\ %{}) do
    path = opts |> Map.get(:path, ".") |> normalize_search_path()
    depth = Map.get(opts, :depth, 3)
    max_entries = Map.get(opts, :max_entries, 200)

    with {:ok, _} <- validate_workspace_path(path) do
      cond do
        depth < 1 or depth > 8 ->
          {:error, "depth must be between 1 and 8"}

        true ->
          do_tree_in_container(agent_id, path, depth, max_entries)
      end
    end
  end

  defp do_tree_in_container(agent_id, path, depth, max_entries) do
    case resolve_container(agent_id) do
      {:ok, container} ->
        full_path = Path.join("/workspace", path)

        # GNU find -printf gives us type/size/path in one go.
        # `%y` = file type (f/d/l), `%s` = size, `%P` = path relative to start
        # NOTE: no sort — `sort -t$'\\t'` is bash-specific and the container
        # shell is dash. find's natural traversal order is good enough.
        cmd =
          "find #{shell_quote(full_path)} -mindepth 1 -maxdepth #{depth} " <>
            "-not -path '*/.git*' -not -path '*/node_modules*' " <>
            "-not -path '*/vendor/bundle*' -not -path '*/_build*' " <>
            "-not -path '*/deps*' -not -path '*/.next*' " <>
            "-not -path '*/dist*' -not -path '*/target*' " <>
            "-not -path '*/.venv*' -not -path '*/__pycache__*' " <>
            "-printf '%y\\t%s\\t%P\\n' 2>/dev/null | head -n #{max_entries + 1}"

        case Docker.exec_in(container, cmd, timeout: 30_000) do
          {:ok, ""} ->
            {:ok, "(empty: #{path})"}

          {:ok, output} ->
            entries = parse_find_output(output)
            truncated = length(entries) > max_entries
            entries = Enum.take(entries, max_entries)
            {:ok, render_tree(entries, path, truncated, max_entries)}

          {:error, reason} ->
            {:error, "tree failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_find_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, "\t", parts: 3) do
        [type, size, path] -> {type, size, path}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp render_tree(entries, root_label, truncated, max_entries) do
    rendered =
      entries
      |> Enum.map(fn {type, size, rel_path} ->
        depth = (rel_path |> Path.split() |> length()) - 1
        indent = String.duplicate("  ", depth)
        name = Path.basename(rel_path)

        case type do
          "d" -> "#{indent}#{name}/"
          "f" -> "#{indent}#{name}  (#{format_size(size)})"
          "l" -> "#{indent}#{name} -> (link)"
          _ -> "#{indent}#{name}"
        end
      end)
      |> Enum.join("\n")

    truncation_note =
      if truncated do
        "\n\n... truncated to #{max_entries} entries. Pass max_entries to see more, or path/depth to narrow."
      else
        ""
      end

    "#{root_label}/\n#{rendered}#{truncation_note}"
  end

  defp format_size(size) when is_binary(size) do
    case Integer.parse(size) do
      {n, _} -> format_size(n)
      _ -> size
    end
  end

  defp format_size(n) when is_integer(n) and n < 1024, do: "#{n} B"
  defp format_size(n) when is_integer(n) and n < 1_048_576, do: "#{Float.round(n / 1024, 1)} KB"
  defp format_size(n) when is_integer(n) and n < 1_073_741_824, do: "#{Float.round(n / 1_048_576, 1)} MB"
  defp format_size(n) when is_integer(n), do: "#{Float.round(n / 1_073_741_824, 1)} GB"
  defp format_size(_), do: "?"

  @doc """
  Combined snapshot of one service: container state, exit code,
  host/container port mapping, recent logs, and an extracted error
  summary. Replaces the 5-6 calls of `docker_compose ps` + `logs` +
  `ports` + `docker port` + `docker stats` that an agent typically
  fans out when something is sick.
  """
  def do_inspect_service(agent_id, name) do
    with {:ok, workspace_id} <- agent_workspace_id(agent_id) do
      container = "#{BoomLooper.Compose.project_name(workspace_id)}-#{name}-1"

      case BoomLooper.Docker.container_state(container) do
        nil ->
          {:ok, format_missing_service(name, container)}

        state ->
          ports = BoomLooper.Docker.container_ports(container)

          logs =
            case BoomLooper.Docker.container_logs(container, tail: 50) do
              {:ok, output} -> output
              _ -> "(could not fetch logs)"
            end

          {:ok, format_service_inspection(name, container, state, ports, logs)}
      end
    end
  end

  defp format_missing_service(name, container) do
    """
    Service `#{name}` (#{container}): NOT FOUND.

    The container doesn't exist. Check `service_containers` to see what's
    actually running, or `docker_compose("ps")` to see compose services.
    """
  end

  defp format_service_inspection(name, container, state, ports, logs) do
    port_lines =
      if map_size(ports) == 0 do
        "  (no published host ports)"
      else
        ports
        |> Enum.map(fn {cport, hport} -> "  #{cport} → host:#{hport}" end)
        |> Enum.join("\n")
      end

    error_lines = extract_error_lines(logs)

    error_section =
      case error_lines do
        [] -> ""
        lines -> "\nDetected errors:\n#{Enum.map_join(lines, "\n", &("  " <> &1))}\n"
      end

    """
    Service: #{name}  (#{container})
    State:   #{state.status}#{exit_summary(state)}
    Published ports:
    #{port_lines}
    #{error_section}
    Last 50 log lines:
    #{logs}
    """
  end

  defp exit_summary(%{status: "running"}), do: ""
  defp exit_summary(%{exit_code: 0}), do: " (exit 0 — clean)"
  defp exit_summary(%{exit_code: 137, oom_killed: true}), do: " (exit 137 — OOM killed)"
  defp exit_summary(%{exit_code: 137}), do: " (exit 137 — SIGKILL)"
  defp exit_summary(%{exit_code: 143}), do: " (exit 143 — SIGTERM)"
  defp exit_summary(%{exit_code: code, error: error}) when is_binary(error) and error != "" do
    " (exit #{code} — #{error})"
  end
  defp exit_summary(%{exit_code: code}), do: " (exit #{code})"
  defp exit_summary(_), do: ""

  # Pull out lines from logs that look like real errors. Heuristic but
  # cheap — saves the agent re-grepping the same logs.
  defp extract_error_lines(logs) when is_binary(logs) do
    logs
    |> String.split("\n")
    |> Enum.filter(fn line ->
      lower = String.downcase(line)

      String.contains?(lower, "error") or
        String.contains?(lower, "fatal") or
        String.contains?(lower, "exception") or
        String.contains?(lower, "panic") or
        String.contains?(lower, "traceback") or
        String.contains?(lower, "cannot") or
        String.contains?(lower, "refused") or
        String.contains?(lower, "denied")
    end)
    |> Enum.take(8)
  end

  defp extract_error_lines(_), do: []

  @doc """
  Read several files in one round trip. The native API forces N
  separate `read_file` calls; this batches them so the discovery
  phase ("look at Gemfile, package.json, README, Procfile.dev")
  is one tool call instead of four.

  Returns a single string with all files concatenated, separated by
  `=== path ===` headers. Files that don't exist or can't be read
  show up as `(error: ...)` so the agent knows what worked and what
  didn't without losing the rest.
  """
  def do_read_files(agent_id, paths) when is_list(paths) do
    cond do
      paths == [] ->
        {:error, "paths list must not be empty"}

      length(paths) > 20 ->
        {:error, "Too many paths (max 20). Read in batches if you really need more."}

      Enum.any?(paths, &(not is_binary(&1))) ->
        {:error, "all paths must be strings"}

      true ->
        results =
          Enum.map(paths, fn path ->
            case do_read_file(agent_id, path) do
              {:ok, content} -> {path, {:ok, content}}
              {:error, reason} -> {path, {:error, reason}}
            end
          end)

        {:ok, format_multi_read(results)}
    end
  end

  defp format_multi_read(results) do
    results
    |> Enum.map(fn
      {path, {:ok, content}} ->
        "=== #{path} (#{byte_size(content)} bytes) ===\n#{content}"

      {path, {:error, reason}} ->
        "=== #{path} (error) ===\n(#{inspect(reason)})"
    end)
    |> Enum.join("\n\n")
  end

  def do_docker(command, timeout_seconds) do
    # Parse command string into args
    args = String.split(command, ~r/\s+/, trim: true)

    Docker.docker(args, timeout: timeout_seconds * 1_000)
  end

  def do_docker_compose(agent_id, command, timeout_seconds) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        project_dir = Path.join([BoomLooper.Workspace.home_dir(), "workspaces", workspace_id])
        volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)

        # Sync files from volume to host before running docker-compose
        # Agent writes to volume, but docker-compose runs on host
        sync_volume_to_host(volume_name, project_dir)

        compose_file = BoomLooper.Compose.compose_path(project_dir)
        project_name = BoomLooper.Compose.project_name(workspace_id)

        # Parse command string into args
        args = String.split(command, ~r/\s+/, trim: true)
        full_args = ["-f", compose_file, "-p", project_name | args]

        BoomLooper.Compose.compose_cmd(full_args, timeout_seconds * 1_000)

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  # Sync .boomlooper/workspace/ from volume to host filesystem
  # This bridges the gap between agent writes (inside volume) and docker-compose (needs host paths)
  defp sync_volume_to_host(volume_name, project_dir) do
    host_dir = Path.join(project_dir, ".boomlooper/workspace")
    File.mkdir_p!(host_dir)

    # Sync Dockerfile (no substitution needed)
    case BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/workspace/Dockerfile") do
      {:ok, content} -> File.write!(Path.join(host_dir, "Dockerfile"), content)
      {:error, _} -> :ok
    end

    # Sync docker-compose.yml with full processing: volume name correction,
    # external volume declaration, host port stripping. The agent may write
    # a literal volume name (e.g. "code-848d") instead of ${CODE_VOLUME},
    # so we must use the YAML-aware process_agent_compose — a simple
    # string replace isn't enough.
    ws_id = Path.basename(project_dir)

    case BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/workspace/docker-compose.yml") do
      {:ok, content} ->
        processed =
          case BoomLooper.Compose.process_agent_compose(content, ws_id) do
            {:ok, json} -> json
            {:error, _} ->
              # Fallback: at least do the string replacement
              content |> String.replace("${CODE_VOLUME}", volume_name)
          end

        # Also fix Dockerfile build context from /workspace to host path
        processed = String.replace(processed, ~r/context["\s:]*\/workspace/, "context: #{host_dir}")
        File.write!(Path.join(host_dir, "docker-compose.yml"), processed)
      {:error, _} ->
        :ok
    end

    :ok
  end

  def do_workspace_info(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} = state when is_binary(workspace_id) ->
        volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)
        project_dir = Path.join([BoomLooper.Workspace.home_dir(), "workspaces", workspace_id])
        compose_project = BoomLooper.Compose.project_name(workspace_id)

        info = %{
          workspace_id: workspace_id,
          volume_name: volume_name,
          project_dir: project_dir,
          compose_project: compose_project,
          compose_file: ".boomlooper/workspace/docker-compose.yml",
          dockerfile: ".boomlooper/workspace/Dockerfile",
          workspace_container: "#{compose_project}-workspace-1",
          working_dir: state[:working_dir],
          bind_mount: state[:bind_mount]
        }

        {:ok, Jason.encode!(info, pretty: true)}

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  def do_volumes(agent_id, action) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        case parse_volume_action(action) do
          {:list} ->
            case BoomLooper.VolumeManager.list_workspace_volumes(workspace_id) do
              {:ok, volumes} -> {:ok, Jason.encode!(volumes, pretty: true)}
              {:error, reason} -> {:error, reason}
            end

          {:ls, volume_name, path} ->
            BoomLooper.VolumeManager.volume_ls(volume_name, path)

          {:info, volume_name} ->
            case BoomLooper.VolumeManager.volume_info(volume_name) do
              nil -> {:error, "Volume not found: #{volume_name}"}
              info -> {:ok, Jason.encode!(info, pretty: true)}
            end
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  defp parse_volume_action(action) do
    case String.split(String.trim(action), ~r/\s+/, parts: 3) do
      ["list"] -> {:list}
      ["ls", volume] -> {:ls, volume, "/"}
      ["ls", volume, path] -> {:ls, volume, path}
      ["info", volume] -> {:info, volume}
      _ -> {:list}  # default
    end
  end

  def do_service_containers(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        prefix = "bl-#{workspace_id}"

        case Docker.docker(["ps", "-a", "--filter", "name=#{prefix}",
                            "--format", "{{.Names}}\t{{.Status}}\t{{.Ports}}"]) do
          {:ok, ""} ->
            {:ok, "No containers found for this workspace."}

          {:ok, output} ->
            {:ok, output}

          {:error, reason} ->
            {:error, "Failed to list containers: #{reason}"}
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  def do_exec_stream(agent_id, command, timeout_seconds) do
    case resolve_container(agent_id) do
      {:ok, container} ->
        # Create the stream message via ChatAgent API (not direct ETS writes)
        stream_msg = %{role: :build, title: command, content: "", timestamp: DateTime.utc_now()}
        stream_msg = BoomLooper.ChatAgent.append_message_ets(agent_id, stream_msg)
        msg_id = if stream_msg, do: stream_msg.id, else: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

        # Run in background Task
        Task.start(fn ->
          port = Port.open(
            {:spawn_executable, System.find_executable("docker")},
            [:binary, :exit_status, {:args, ["exec", container, "sh", "-c", command]}]
          )

          stream_port_output(agent_id, port, command, msg_id, "", timeout_seconds * 1_000)
        end)

        {:ok, "Streaming command started: #{command}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_port_output(agent_id, port, command, msg_id, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data

        # Update message content in ETS
        BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | content: acc}
        end)

        # Broadcast to LiveView — include msg_id so the LiveView uses the same ID
        Phoenix.PubSub.broadcast(BoomLooper.PubSub,
          "chat_agent:#{agent_id}",
          {:stream_output, agent_id, data, command, msg_id})

        stream_port_output(agent_id, port, command, msg_id, acc, timeout)

      {^port, {:exit_status, code}} ->
        # Mark as done in ETS
        BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | role: :build_done, content: acc}
        end)

        status = if code == 0, do: "completed", else: "exited (code #{code})"
        Phoenix.PubSub.broadcast(BoomLooper.PubSub,
          "chat_agent:#{agent_id}",
          {:chat_message, agent_id, %{role: :system, content: "Command #{status}", timestamp: DateTime.utc_now()}})
    after
      timeout ->
        Port.close(port)
        BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | role: :build_failed, content: acc}
        end)
        Phoenix.PubSub.broadcast(BoomLooper.PubSub,
          "chat_agent:#{agent_id}",
          {:chat_message, agent_id, %{role: :system, content: "Command timed out after #{div(timeout, 1_000)}s", timestamp: DateTime.utc_now()}})
    end
  end

  # --- Private ---

  # All agents exec into the compose "workspace" service
  defp resolve_container(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        container = ServiceManager.service_container_name(workspace_id, "workspace")
        {:ok, container}

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  # Resolve a specific service container by compose service name
  defp resolve_service_container(agent_id, service_name) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        container = ServiceManager.service_container_name(workspace_id, service_name)

        if Docker.container_running?(container) || container_exists?(container) do
          {:ok, container}
        else
          {:error, "Service #{service_name} not found"}
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  defp container_exists?(name) do
    match?({:ok, _}, Docker.docker(["inspect", "--format", "{{.Name}}", name]))
  end
end
