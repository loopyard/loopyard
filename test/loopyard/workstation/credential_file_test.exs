defmodule Loopyard.Workstation.CredentialFileTest do
  @moduledoc """
  A file-shaped sign-in (Codex's `auth.json`) stored with an identity and
  delivered per identity. The delivery script is a pure string that `Env` runs
  in its transient volume container; here it runs with `sh` against a tmp dir
  standing in for the home volume, so what lands — path, mode, marker — and
  which copy wins are checked for real, with no Docker.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Harness.Catalog
  alias Loopyard.Workstation
  alias Loopyard.Workstation.{CredentialFile, Env}

  @auth ~s({"tokens":{"refresh_token":"rt-1"},"last_refresh":"2026-11-12T00:00:00Z"})

  setup do
    id = "cred-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(Workstation.dir(id)) end)
    %{id: id}
  end

  # Store without the side effects `put/3` adds (home sync, agent reload).
  defp store!(id, body) do
    path = Path.join([Workstation.dir(id), "credentials", "codex", "auth.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  defp deliver!(id, root, guest? \\ false) do
    script = CredentialFile.deliver_script(id, root, guest?) <> "true"
    assert {_, 0} = System.cmd("sh", ["-c", script], stderr_to_stdout: true)
  end

  defp mode(path), do: File.stat!(path).mode |> Bitwise.band(0o777)

  test "the Catalog names which harness has a file sign-in, and where" do
    assert CredentialFile.harnesses() == [{:codex, %{home_env: "CODEX_HOME", name: "auth.json"}}]
    assert CredentialFile.home_envs() == ["CODEX_HOME"]
    assert CredentialFile.home_dir(:codex, "brad") == ".loopyard/codex.brad"
  end

  test "put/3 stores a JSON credential with the identity, mode 600", %{id: id} do
    :ok = Workstation.create(id)
    refute CredentialFile.stored?(id, :codex)
    assert :ok = CredentialFile.put(id, :codex, @auth)
    assert CredentialFile.stored?(id, :codex)

    path = Path.join([Workstation.dir(id), "credentials", "codex", "auth.json"])
    assert File.read!(path) == @auth
    assert mode(path) == 0o600
    assert mode(Path.dirname(path)) == 0o700
  end

  test "put/3 refuses what isn't a credential", %{id: id} do
    assert {:error, :not_a_credential} = CredentialFile.put(id, :codex, "not json")
    assert {:error, :not_a_credential} = CredentialFile.put(id, :codex, "{}")
    assert {:error, :no_credential_file} = CredentialFile.put(id, :claude, @auth)
    assert {:error, :invalid_identity} = CredentialFile.put("../x", :codex, @auth)
    refute CredentialFile.stored?(id, :codex)
  end

  @tag :tmp_dir
  test "delivery writes the per-identity file at mode 600 with its generation", %{
    id: id,
    tmp_dir: root
  } do
    store!(id, @auth)
    deliver!(id, root)

    file = Path.join(root, ".loopyard/codex.#{id}/auth.json")
    assert File.read!(file) == @auth
    assert mode(file) == 0o600
    assert mode(Path.dirname(file)) == 0o700

    assert File.read!(Path.join(root, ".loopyard/codex.#{id}/.loopyard-generation")) ==
             CredentialFile.generation(@auth)
  end

  @tag :tmp_dir
  test "a copy the CLI refreshed in place wins over the stored one — until a new sign-in", %{
    id: id,
    tmp_dir: root
  } do
    store!(id, @auth)
    deliver!(id, root)
    file = Path.join(root, ".loopyard/codex.#{id}/auth.json")

    # Codex refreshed its tokens inside the container.
    refreshed = ~s({"tokens":{"refresh_token":"rt-2"}})
    File.write!(file, refreshed)
    deliver!(id, root)
    assert File.read!(file) == refreshed

    # The human signed in again: the new stored generation replaces it.
    again = ~s({"tokens":{"refresh_token":"rt-new-sign-in"}})
    store!(id, again)
    deliver!(id, root)
    assert File.read!(file) == again
  end

  @tag :tmp_dir
  test "a guest identity without a sign-in gets an empty dir; an owner gets nothing", %{
    id: id,
    tmp_dir: root
  } do
    deliver!(id, root, false)
    refute File.exists?(Path.join(root, ".loopyard/codex.#{id}"))

    deliver!(id, root, true)
    assert File.dir?(Path.join(root, ".loopyard/codex.#{id}"))
    refute File.exists?(Path.join(root, ".loopyard/codex.#{id}/auth.json"))
  end

  test "the identity env file exports CODEX_HOME only where it should", %{id: id} do
    export = ~s|export CODEX_HOME="$HOME/.loopyard/codex.#{id}"\n|

    # Own identity, no sign-in: the legacy ~/.codex keeps working.
    assert CredentialFile.exports(id, false) == ""
    # A guest never falls through to the host's ~/.codex.
    assert CredentialFile.exports(id, true) == export

    store!(id, @auth)
    assert CredentialFile.exports(id, false) == export

    body = Env.identity_file_body(%{"GH_TOKEN" => "gh"}, CredentialFile.exports(id, false))
    [unset | rest] = String.split(body, "\n")
    # Unset with the tokens, so a host's own CODEX_HOME can't leak through.
    assert unset =~ "CODEX_HOME"
    assert String.trim_trailing(export) in rest
    # The value is a path, never the credential.
    refute body =~ "rt-1"
  end

  test "credentialed?/2 counts a stored subscription sign-in for the identity", %{id: id} do
    :ok = Workstation.create(id)
    refute Catalog.credentialed?(:codex, id)
    refute Catalog.credentialed?(:claude, id)

    store!(id, @auth)
    assert Catalog.credentialed?(:codex, id)
    # A Codex sign-in unlocks Codex only.
    refute Catalog.credentialed?(:claude, id)

    assert %{harnesses: [:codex]} = Enum.find(Workstation.accounts(), &(&1.id == id))
  end

  test "an identity whose only credential is a sign-in file still materializes", %{id: id} do
    :ok = Workstation.create(id)
    File.write!(Path.join(Workstation.dir(id), "env.json"), "{}")
    assert {:error, :refusing_empty_env} = Env.sync_identity_into(id, "host-#{id}")

    store!(id, @auth)
    refute Env.sync_identity_into(id, "host-#{id}") == {:error, :refusing_empty_env}
  end
end
