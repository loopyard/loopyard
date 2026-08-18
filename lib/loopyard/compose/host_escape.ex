defmodule Loopyard.Compose.HostEscape do
  @moduledoc """
  Rejects the ways a compose SERVICE can punch through the container
  boundary — privileged mode, added capabilities, dropped confinement,
  host/other-container namespaces, direct devices, and a build context
  that resolves on the host. Extracted from `Loopyard.Compose` so the
  validator stays under its size cap; the checks are unchanged (#79).
  """

  def validate(compose) do
    services = Map.get(compose, "services", %{}) || %{}

    Enum.reduce_while(services, :ok, fn {name, svc}, _acc ->
      case check_host_escape(name, svc) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_host_escape(name, svc) when is_map(svc) do
    cond do
      svc["privileged"] == true ->
        {:error,
         "service #{name}: `privileged: true` is not allowed. " <>
           "Privileged containers can remount the host filesystem and " <>
           "reach other workspaces. Drop the key."}

      # `cap_add` grants Linux capabilities. SYS_ADMIN alone (mount, cgroup
      # release_agent) is a known breakout, so no capability is safe to grant
      # inside the sandbox — reject the whole key rather than allowlist.
      is_list(svc["cap_add"]) and svc["cap_add"] != [] ->
        {:error,
         "service #{name}: `cap_add:` is not allowed (#{inspect(svc["cap_add"])}). " <>
           "Added capabilities (SYS_ADMIN, SYS_PTRACE, …) let a container break " <>
           "out of the sandbox. Remove the key."}

      # `security_opt` can drop seccomp/apparmor confinement, the other half
      # of most breakout recipes.
      is_list(svc["security_opt"]) and svc["security_opt"] != [] ->
        {:error,
         "service #{name}: `security_opt:` is not allowed (#{inspect(svc["security_opt"])}). " <>
           "Unconfining seccomp/apparmor removes the syscall filtering the " <>
           "sandbox relies on. Remove the key."}

      svc["network_mode"] == "host" ->
        {:error,
         "service #{name}: `network_mode: host` is not allowed. " <>
           "Host networking lets this service bind to the host's ports " <>
           "(clashing with other workspaces) and reach host services " <>
           "directly. Use the default bridge network; expose ports via " <>
           "the `ports:` key so Loopyard can route them."}

      # Only `host` and `container:<name>` cross the workspace boundary;
      # `service:<x>` references a service in THIS compose file, which is fine.
      host_or_container_ns?(svc["network_mode"]) ->
        {:error,
         "service #{name}: `network_mode: #{svc["network_mode"]}` is not allowed — " <>
           "joining another container's network namespace crosses into another " <>
           "workspace. Use `service:<x>` to share with a service in this file."}

      svc["pid"] == "host" ->
        {:error,
         "service #{name}: `pid: host` is not allowed — it exposes every " <>
           "host process (including other workspaces' containers) to this " <>
           "service. Remove the key."}

      host_or_container_ns?(svc["pid"]) ->
        {:error,
         "service #{name}: `pid: #{svc["pid"]}` is not allowed — joining another " <>
           "container's PID namespace reaches into another workspace (ptrace, " <>
           "/proc). Use `service:<x>` to share with a service in this file."}

      svc["ipc"] == "host" ->
        {:error,
         "service #{name}: `ipc: host` is not allowed — it shares the host's " <>
           "IPC namespace across workspaces. Remove the key."}

      svc["uts"] == "host" ->
        {:error,
         "service #{name}: `uts: host` is not allowed — it shares the host's " <>
           "UTS namespace. Remove the key."}

      svc["cgroup"] == "host" ->
        {:error,
         "service #{name}: `cgroup: host` is not allowed — a host cgroup " <>
           "namespace is a known breakout vector. Remove the key."}

      svc["userns_mode"] == "host" ->
        {:error,
         "service #{name}: `userns_mode: host` is not allowed — it disables " <>
           "user-namespace isolation. Remove the key."}

      is_list(svc["group_add"]) and svc["group_add"] != [] ->
        {:error,
         "service #{name}: `group_add:` is not allowed (#{inspect(svc["group_add"])}). " <>
           "Adding host groups (e.g. docker, 0) can grant access to the daemon " <>
           "socket or host resources. Remove the key."}

      is_map(svc["sysctls"]) and svc["sysctls"] != %{} ->
        {:error,
         "service #{name}: `sysctls:` is not allowed. Tuning kernel parameters " <>
           "affects the shared host kernel. Remove the key."}

      is_list(svc["sysctls"]) and svc["sysctls"] != [] ->
        {:error, "service #{name}: `sysctls:` is not allowed. Remove the key."}

      is_list(svc["devices"]) and svc["devices"] != [] ->
        {:error,
         "service #{name}: `devices:` is not allowed (#{inspect(svc["devices"])}). " <>
           "Direct host device access breaks the workspace boundary. Remove " <>
           "the key or find a userspace alternative."}

      true ->
        check_build(name, svc["build"])
    end
  end

  defp check_host_escape(_name, _), do: :ok

  # `host` and `container:<name>` join a namespace outside the workspace;
  # `service:<x>` (same compose file) does not.
  defp host_or_container_ns?(v) when is_binary(v), do: String.starts_with?(v, "container:")
  defp host_or_container_ns?(_), do: false

  # The build context/dockerfile are resolved as HOST paths at build time
  # (only the literal `/workspace` is rewritten to the workspace's host dir),
  # so an arbitrary `context:` reads the host filesystem. Allow only the
  # workspace context and relative paths that don't climb out with `..`.
  defp check_build(_name, nil), do: :ok

  defp check_build(name, context) when is_binary(context),
    do: check_build_context(name, context)

  defp check_build(name, %{} = build) do
    with :ok <- check_build_context(name, build["context"] || "/workspace") do
      case build["dockerfile"] do
        nil ->
          :ok

        df when is_binary(df) ->
          if String.contains?(df, "..") do
            {:error,
             "service #{name}: build `dockerfile: #{df}` is not allowed — it must " <>
               "not climb out of the build context with `..`."}
          else
            :ok
          end

        _ ->
          :ok
      end
    end
  end

  defp check_build(_name, _), do: :ok

  defp check_build_context(_name, "/workspace"), do: :ok
  defp check_build_context(_name, "/workspace/" <> _), do: :ok

  defp check_build_context(name, context) when is_binary(context) do
    cond do
      String.starts_with?(context, "/") ->
        {:error,
         "service #{name}: build `context: #{context}` is not allowed — an " <>
           "absolute path other than `/workspace` resolves on the host. Use " <>
           "`context: /workspace`."}

      String.contains?(context, "..") ->
        {:error,
         "service #{name}: build `context: #{context}` is not allowed — it climbs " <>
           "out of the workspace with `..`. Use `context: /workspace`."}

      true ->
        :ok
    end
  end

  defp check_build_context(_name, _), do: :ok
end
