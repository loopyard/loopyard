defmodule BoomLooperWeb.Live.WorkspaceLive.Components.Viewers.FileTypeTest do
  use ExUnit.Case, async: true

  alias BoomLooperWeb.Live.WorkspaceLive.Components.Viewers.FileType

  describe "detect/1" do
    test "recognizes common text extensions" do
      for ext <- ~w(.ex .rb .py .js .ts .json .yml .md .txt .sh .sql .go .rs .html .css) do
        assert FileType.detect("file#{ext}") == :text, "expected :text for #{ext}"
      end
    end

    test "recognizes image extensions" do
      for ext <- ~w(.png .jpg .jpeg .gif .webp .svg .ico) do
        assert FileType.detect("file#{ext}") == :image, "expected :image for #{ext}"
      end
    end

    test "recognizes binary extensions" do
      for ext <- ~w(.zip .tar .gz .exe .pdf .sqlite .wasm) do
        assert FileType.detect("file#{ext}") == :binary, "expected :binary for #{ext}"
      end
    end

    test "recognizes extensionless config files" do
      for name <- ~w(Gemfile Rakefile Makefile Dockerfile Procfile) do
        assert FileType.detect(name) == :text, "expected :text for #{name}"
      end
    end

    test "case insensitive" do
      assert FileType.detect("FILE.JS") == :text
      assert FileType.detect("PHOTO.PNG") == :image
    end
  end

  describe "language/1" do
    test "maps extensions to languages" do
      assert FileType.language("app.ex") == "elixir"
      assert FileType.language("app.rb") == "ruby"
      assert FileType.language("app.py") == "python"
      assert FileType.language("app.js") == "javascript"
      assert FileType.language("app.ts") == "typescript"
      assert FileType.language("app.go") == "go"
      assert FileType.language("app.rs") == "rust"
      assert FileType.language("app.json") == "json"
      assert FileType.language("app.yml") == "yaml"
      assert FileType.language("app.md") == "markdown"
      assert FileType.language("app.sql") == "sql"
      assert FileType.language("app.html") == "html"
      assert FileType.language("app.css") == "css"
    end

    test "recognizes Ruby special filenames" do
      for name <- ~w(Gemfile Rakefile Guardfile Vagrantfile Berksfile Capfile
                     Podfile Dangerfile Fastfile Brewfile config.ru .pryrc .irbrc .gemrc) do
        assert FileType.language(name) == "ruby", "expected ruby for #{name}"
      end
    end

    test "recognizes Ruby extensions" do
      for ext <- ~w(.rb .rake .gemspec .ru .builder .jbuilder .thor) do
        assert FileType.language("file#{ext}") == "ruby", "expected ruby for #{ext}"
      end
    end

    test "recognizes other special filenames" do
      assert FileType.language("Dockerfile") == "dockerfile"
      assert FileType.language("Makefile") == "makefile"
      assert FileType.language("Procfile") == "yaml"
      assert FileType.language(".bashrc") == "bash"
      assert FileType.language(".zshrc") == "bash"
      assert FileType.language(".gitignore") == "bash"
      assert FileType.language(".env") == "bash"
    end

    test "returns nil for unknown" do
      assert FileType.language("file.xyz") == nil
    end
  end

  describe "binary_content?/1" do
    test "detects null bytes" do
      assert FileType.binary_content?("hello\0world")
    end

    test "text content is not binary" do
      refute FileType.binary_content?("hello world\nline 2")
    end

    test "empty string is not binary" do
      refute FileType.binary_content?("")
    end
  end
end
