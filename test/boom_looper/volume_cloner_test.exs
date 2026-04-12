defmodule BoomLooper.VolumeClonerTest do
  use ExUnit.Case

  alias BoomLooper.VolumeCloner

  describe "inject_token/2" do
    test "converts SSH URL to HTTPS with token" do
      url = VolumeCloner.inject_token("git@github.com:owner/repo.git", "ghp_abc123")
      assert url == "https://ghp_abc123@github.com/owner/repo.git"
    end

    test "injects token into HTTPS URL" do
      url = VolumeCloner.inject_token("https://github.com/owner/repo.git", "ghp_abc123")
      assert url == "https://ghp_abc123@github.com/owner/repo.git"
    end

    test "returns non-github URLs unchanged" do
      url = VolumeCloner.inject_token("https://gitlab.com/owner/repo.git", "token")
      assert url == "https://gitlab.com/owner/repo.git"
    end

    test "handles URL without .git suffix" do
      url = VolumeCloner.inject_token("https://github.com/owner/repo", "tok")
      assert url == "https://tok@github.com/owner/repo"
    end
  end

  # clone_into_volume needs Docker + a real git repo — tagged :docker
  describe "clone_into_volume/3" do
    @describetag :docker

    test "returns error when volume creation fails" do
      # Empty volume name will fail
      assert {:error, _} = VolumeCloner.clone_into_volume("", "https://github.com/test/repo.git")
    end
  end
end
