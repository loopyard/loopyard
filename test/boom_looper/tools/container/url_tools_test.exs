defmodule BoomLooper.Tools.Container.UrlToolsTest do
  use ExUnit.Case, async: true

  alias BoomLooper.Tools.Container.{AppUrl, FileUrl}

  describe "AppUrl.parse_base_url/1" do
    test "parses localhost URL" do
      uri = AppUrl.parse_base_url("http://localhost:4000")
      assert uri.scheme == "http"
      assert uri.host == "localhost"
      assert uri.port == 4000
    end

    test "parses LAN IP URL" do
      uri = AppUrl.parse_base_url("http://10.0.1.123:4000")
      assert uri.scheme == "http"
      assert uri.host == "10.0.1.123"
      assert uri.port == 4000
    end

    test "parses tunnel URL with HTTPS" do
      uri = AppUrl.parse_base_url("https://myapp.cloudflare.dev")
      assert uri.scheme == "https"
      assert uri.host == "myapp.cloudflare.dev"
    end

    test "falls back to localhost for nil" do
      uri = AppUrl.parse_base_url(nil)
      assert uri.host == "localhost"
      assert uri.scheme == "http"
    end

    test "falls back to localhost for garbage" do
      uri = AppUrl.parse_base_url("")
      assert uri.host == "localhost"
    end
  end

  describe "FileUrl.parse_base_url/1" do
    test "parses LAN IP" do
      uri = FileUrl.parse_base_url("http://10.0.1.123:4000")
      assert uri.host == "10.0.1.123"
      assert uri.port == 4000
    end

    test "nil falls back to localhost with endpoint port" do
      uri = FileUrl.parse_base_url(nil)
      assert uri.host == "localhost"
      assert is_integer(uri.port)
    end
  end

  describe "URI construction" do
    test "app_url builds correct URI from LAN IP base + Docker port + path" do
      base = AppUrl.parse_base_url("http://10.0.1.123:4000")
      url = %URI{base | port: 32794, path: "/code/my-article"} |> URI.to_string()
      assert url == "http://10.0.1.123:32794/code/my-article"
    end

    test "app_url builds correct URI from tunnel base + Docker port + path" do
      base = AppUrl.parse_base_url("https://myapp.cloudflare.dev")
      url = %URI{base | port: 32794, path: "/users/1"} |> URI.to_string()
      assert url == "https://myapp.cloudflare.dev:32794/users/1"
    end

    test "file_url builds correct URI from LAN IP base" do
      base = FileUrl.parse_base_url("http://10.0.1.123:4000")
      url = %URI{base | path: "/projects/abc/workspaces/def/volumes/vol/files/Gemfile"} |> URI.to_string()
      assert url == "http://10.0.1.123:4000/projects/abc/workspaces/def/volumes/vol/files/Gemfile"
    end
  end
end
