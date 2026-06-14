defmodule Loopyard.Workstation.Integration do
  @moduledoc """
  Registry of workstation integrations — each tool you might wire into the box
  (GitHub, Claude, Codex, Fly…). Every entry is **data**: a label, the method it
  sets up by (`:console` / `:file` / `:env`), the bits that method needs, a cheap
  "connected?" probe, and a markdown doc (`priv/integrations/<id>.md`) that's the
  single source of truth for humans *and* agents.

  Adding a tool = a markdown file + a map entry here. See plans/integrations.md.

  Integrations are **additive** — nothing here is required for an agent to run.
  """
  alias Loopyard.Workstation.{Container, Env}

  @integrations [
    %{
      id: "github",
      label: "GitHub",
      method: :console,
      console: "gh auth login",
      status_cmd: "gh auth status",
      status_marker: "Logged in",
      lands: "~/.config/gh (file, live)"
    },
    %{
      id: "claude",
      label: "Claude",
      method: :file,
      file: ".claude/.credentials.json",
      mac: "cat ~/.claude/.credentials.json",
      lands: "~/.claude (file, live)"
    },
    %{
      id: "codex",
      label: "Codex",
      method: :file,
      file: ".codex/auth.json",
      mac: "cat ~/.codex/auth.json",
      lands: "~/.codex/auth.json (file, live)"
    },
    %{
      id: "fly",
      label: "Fly",
      method: :env,
      env: "FLY_ACCESS_TOKEN",
      mac: "fly auth token",
      lands: "FLY_ACCESS_TOKEN (env, Restart)"
    }
  ]

  @doc "All integrations (display order)."
  def all, do: @integrations

  @doc "One integration by id, or nil."
  def get(id), do: Enum.find(@integrations, &(&1.id == id))

  @doc "The raw markdown doc for an integration (single source for humans + agents)."
  @spec doc(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def doc(id) do
    path = Application.app_dir(:loopyard, "priv/integrations/#{id}.md")

    case File.read(path) do
      {:ok, md} -> {:ok, md}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Cheap "is this set up?" probe for a given workstation `id`. Greps a marker
  rather than trusting exit codes. Hits the container for `:file`/`:console`;
  `:env` is just a key lookup.
  """
  @spec connected?(map(), String.t()) :: boolean()
  def connected?(%{method: :env, env: key}, id), do: key in Env.keys(id)

  def connected?(%{method: :file, file: rel}, id) do
    exec_says?("test -f '/root/#{rel}' && echo CONNECTED", "CONNECTED", id)
  end

  def connected?(%{method: :console, status_cmd: cmd, status_marker: marker}, id) do
    exec_says?(cmd, marker, id)
  end

  def connected?(_, _id), do: false

  defp exec_says?(cmd, marker, id) do
    case Container.exec(cmd, id) do
      {:ok, out} -> String.contains?(out, marker)
      {:error, out} when is_binary(out) -> String.contains?(out, marker)
      _ -> false
    end
  end
end
