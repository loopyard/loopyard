defmodule BoomLooper.Workspace.Setup.ErrorTest do
  use ExUnit.Case, async: true

  alias BoomLooper.Workspace.Setup.Error

  describe "classify/2" do
    test "disk full surfaces a permanent error with concrete remediation" do
      err = Error.classify("rsync: write failed: No space left on device", :seeding)

      assert err.code == :disk_full
      assert err.transient? == false
      assert err.phase == :seeding
      assert err.why =~ "disk is full"
      assert err.action =~ "Retry"
    end

    test "permission denied is permanent" do
      err = Error.classify("Permission denied (publickey).", :seeding)
      assert err.code == :permissions
      assert err.transient? == false
    end

    test "missing source path atom" do
      err = Error.classify(:enoent, :seeding)
      assert err.code == :source_path_missing
      assert err.transient? == false
    end

    test "missing source path tuple from adapter" do
      err = Error.classify({:source_path_missing, "/tmp/gone"}, :seeding)
      assert err.code == :source_path_missing
    end

    test "docker daemon unreachable is transient" do
      err =
        Error.classify(
          "Cannot connect to the Docker daemon at unix:///var/run/docker.sock",
          :volume
        )

      assert err.code == :docker_daemon_unreachable
      assert err.transient? == true
    end

    test "image pull i/o timeout is transient" do
      err =
        Error.classify(
          "failed to resolve reference \"docker.io/library/alpine:latest\": i/o timeout",
          :seeding
        )

      assert err.code == :image_pull_failure
      assert err.transient? == true
    end

    test "network failure during git clone is transient" do
      err =
        Error.classify(
          "fatal: unable to access 'https://github.com/x/y.git/': Could not resolve host",
          :worktree
        )

      assert err.code == :network_timeout
      assert err.transient? == true
    end

    test "unknown error never auto-retries" do
      err = Error.classify("this is some weirdness we have never seen", :seeding)
      assert err.code == :unknown
      assert err.transient? == false
      assert err.action =~ "/system/events"
    end

    test "interrupted_by_restart surfaces actionable error" do
      err = Error.classify(:interrupted_by_restart, :seeding)
      assert err.code == :interrupted_by_restart
      assert err.action =~ "Retry"
    end

    test "invalid git url is permanent" do
      err = Error.classify("fatal: Authentication failed for 'https://github.com/...'", :worktree)
      assert err.code == :invalid_git_url
      assert err.transient? == false
    end

    test "saga step_failed shape is unwrapped to inner reason" do
      raw = {:step_failed, :seeding, "No space left on device"}
      err = Error.classify(raw, :seeding)
      assert err.code == :disk_full
    end

    test "carries raw error through for telemetry" do
      raw = {:exception, "RuntimeError: something"}
      err = Error.classify(raw, :seeding)
      assert err.raw == raw
    end
  end

  describe "transient?/2" do
    test "thin convenience wrapper agrees with classify" do
      assert Error.transient?("Cannot connect to the Docker daemon", :seeding) == true
      assert Error.transient?(:enoent, :seeding) == false
    end
  end
end
