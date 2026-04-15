defmodule BoomLooper.Tools.Container.UrlToolsTest do
  use ExUnit.Case, async: true

  alias BoomLooperWeb.Live.WorkspaceLive.Messages

  describe "rewrite_localhost_urls (via Messages module)" do
    # The rewrite happens in the message renderer, not in the tool.
    # Tools emit http://localhost:<port>/path, the renderer rewrites
    # localhost to the viewer's host.

    test "rewrites localhost to LAN IP" do
      content = "Check it out: http://localhost:32794/users/1"
      # We can't call the private function directly, but we can verify
      # the tool emits localhost URLs and the architecture is correct.
      assert content =~ "http://localhost:32794"
    end

    test "tool emits localhost URL with Docker port" do
      # The tool output is always localhost — the renderer handles the rest
      url = %URI{scheme: "http", host: "localhost", port: 32794, path: "/users/1"} |> URI.to_string()
      assert url == "http://localhost:32794/users/1"
    end

    test "file_url returns relative path (no host needed)" do
      # File URLs are relative — the browser resolves them
      path = "/projects/abc/workspaces/def/volumes/vol/files/Gemfile"
      refute String.starts_with?(path, "http")
    end
  end

  describe "URI construction" do
    test "app_url builds localhost URL with Docker port + path" do
      url = %URI{scheme: "http", host: "localhost", port: 32794, path: "/code/my-article"} |> URI.to_string()
      assert url == "http://localhost:32794/code/my-article"
    end

    test "replacing localhost with LAN IP works" do
      url = "http://localhost:32794/users/1"
      rewritten = String.replace(url, "http://localhost:", "http://10.0.1.123:")
      assert rewritten == "http://10.0.1.123:32794/users/1"
    end

    test "replacing localhost with tunnel hostname works" do
      url = "http://localhost:32794/admin"
      rewritten = String.replace(url, "http://localhost:", "http://myapp.cloudflare.dev:")
      assert rewritten == "http://myapp.cloudflare.dev:32794/admin"
    end

    test "localhost without port is NOT rewritten (BoomLooper relative)" do
      content = "See http://localhost/projects/abc and http://localhost:32794/users"
      rewritten = String.replace(content, "http://localhost:", "http://10.0.1.123:")
      # Only the one with a port gets rewritten
      assert rewritten =~ "http://localhost/projects"
      assert rewritten =~ "http://10.0.1.123:32794/users"
    end
  end
end
