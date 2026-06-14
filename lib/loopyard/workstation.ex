defmodule Loopyard.Workstation do
  @moduledoc """
  Named **workstations** — each one is a *person's identity*: their Dockerfile
  (image), their env vars, their logins (the `$HOME` volume). `brad`, `jamie`.
  Profile, user, and workstation are the same concept.

  You **operate as** a workstation (`current/0`); agents you spin up inherit it —
  its image, its creds, its name on commits. That's how an agent knows which
  image to use: it doesn't ask, it follows the driver's identity. See
  plans/integrations.md.

  On disk: `<LOOPYARD_HOME>/workstations/<id>/` holds `Dockerfile` + `env.json`.
  Docker holds the runtime: image `loopyard-ws-<id>`, volume `loopyard-ws-<id>-home`.
  """
  alias Loopyard.Workspace

  @default_id "default"
  @id_re ~r/^[a-z0-9][a-z0-9-]{0,38}$/

  @doc "Root of all workstation dirs."
  def base_dir, do: Path.join(Workspace.home_dir(), "workstations")

  @doc "Dir for one workstation: `<LOOPYARD_HOME>/workstations/<id>/`."
  def dir(id), do: Path.join(base_dir(), id)

  @doc "Is `id` a legal workstation id (lowercase, digits, dashes)?"
  def valid_id?(id), do: is_binary(id) and Regex.match?(@id_re, id)

  @doc "Does this workstation exist on disk?"
  def exists?(id), do: valid_id?(id) and File.dir?(dir(id))

  @doc "All workstation ids (sorted). Ensures at least the default exists."
  def list do
    _ = ensure_default()

    case File.ls(base_dir()) do
      {:ok, entries} -> entries |> Enum.filter(&File.dir?(dir(&1))) |> Enum.sort()
      _ -> [@default_id]
    end
  end

  @doc "Create a workstation dir (seeds its Dockerfile). Returns `:ok | {:error, _}`."
  def create(id) do
    cond do
      not valid_id?(id) -> {:error, :invalid_id}
      exists?(id) -> {:error, :exists}
      true ->
        File.mkdir_p!(dir(id))
        if id == @default_id, do: migrate_legacy(id), else: seed_dockerfile(id)
        :ok
    end
  end

  @doc "The workstation you're operating as (the identity agents inherit)."
  def current do
    case File.read(current_path()) do
      {:ok, raw} ->
        id = String.trim(raw)
        if exists?(id), do: id, else: ensure_default()

      _ ->
        ensure_default()
    end
  end

  @doc "Switch the identity you operate as."
  def set_current(id) do
    cond do
      not exists?(id) -> {:error, :not_found}
      true -> File.write!(current_path(), id) && :ok
    end
  end

  # --- Docker naming (per identity) ---
  # The `default` workstation keeps the LEGACY names so the existing container,
  # home volume (your transferred creds), and image aren't orphaned by the move
  # to named workstations. New workstations use the clean `loopyard-ws-<id>` scheme.
  def container_name(@default_id), do: "loopyard-workstation"
  def container_name(id), do: "loopyard-ws-#{id}"

  def home_volume(@default_id), do: "loopyard-workstation-home"
  def home_volume(id), do: "loopyard-ws-#{id}-home"

  def image_tag(@default_id), do: "loopyard-workspace-base:latest"
  def image_tag(id), do: "loopyard-ws-#{id}:latest"

  @doc "The default identity id."
  def default_id, do: @default_id

  # --- internals ---

  defp ensure_default do
    unless exists?(@default_id), do: create(@default_id)
    @default_id
  end

  defp current_path, do: Path.join(base_dir(), ".current")

  # Seed a new workstation's Dockerfile from the stock base shipped in priv.
  defp seed_dockerfile(id) do
    target = Path.join(dir(id), "Dockerfile")
    stock = Application.app_dir(:loopyard, "priv/workspace-base/Dockerfile")
    if File.exists?(stock), do: File.cp!(stock, target)
    true
  end

  # Bring the pre-named-workstations singleton (`<LOOPYARD_HOME>/workstation/`)
  # forward into `workstations/default/` — Dockerfile + env carry over (the home
  # volume + image keep their legacy names, so nothing is lost).
  defp migrate_legacy(id) do
    legacy = Path.join(Workspace.home_dir(), "workstation")

    for f <- ["Dockerfile", "env.json"] do
      src = Path.join(legacy, f)
      dst = Path.join(dir(id), f)
      if File.exists?(src) and not File.exists?(dst), do: File.cp!(src, dst)
    end

    unless File.exists?(Path.join(dir(id), "Dockerfile")), do: seed_dockerfile(id)
    true
  end
end

