defmodule BoomLooperWeb.Live.ChatLive.Components.Viewers.FileType do
  @moduledoc """
  Detect file type from path and content for choosing the right viewer.
  Pure functions — no side effects.
  """

  @text_extensions ~w(.ex .exs .erl .rb .py .js .ts .tsx .jsx .json .yml .yaml
    .toml .xml .html .heex .css .scss .sass .less .md .txt .sh .bash .zsh
    .fish .dockerfile .gitignore .env .env.example .editorconfig .tool-versions
    .lock .log .csv .sql .graphql .gql .vue .svelte .rs .go .java .kt .swift
    .c .h .cpp .hpp .cs .php .lua .r .jl .zig .nim .tf .hcl .conf .cfg .ini
    .properties .makefile .rake .gemfile .gemspec .podfile .csproj .sln
    .gradle .pom .cabal .nix .dhall .prisma .proto)

  @image_extensions ~w(.png .jpg .jpeg .gif .webp .svg .ico .bmp)

  @binary_extensions ~w(.zip .tar .gz .bz2 .xz .7z .rar .jar .war .ear
    .whl .egg .gem .deb .rpm .dmg .iso .bin .exe .dll .so .dylib .o .a
    .wasm .pdf .doc .docx .xls .xlsx .ppt .pptx .sqlite .db .dat)

  @type file_type :: :text | :image | :binary | :unknown

  @doc "Detect file type from path extension."
  @spec detect(String.t()) :: file_type()
  def detect(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()
    name = Path.basename(path) |> String.downcase()

    cond do
      ext in @image_extensions -> :image
      ext in @binary_extensions -> :binary
      ext in @text_extensions -> :text
      name in ~w(gemfile rakefile makefile dockerfile procfile guardfile vagrantfile brewfile) -> :text
      ext == "" and name_suggests_text?(name) -> :text
      ext == "" -> :unknown
      true -> :text
    end
  end

  @doc "Detect language for syntax highlighting from file extension."
  @spec language(String.t()) :: String.t() | nil
  def language(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()
    name = Path.basename(path) |> String.downcase()

    cond do
      ext in ~w(.ex .exs) -> "elixir"
      ext in ~w(.erl .hrl) -> "erlang"
      ext in ~w(.rb .rake .gemspec .ru .builder .jbuilder .thor) -> "ruby"
      ext in ~w(.py .pyw) -> "python"
      ext in ~w(.js .mjs .cjs) -> "javascript"
      ext in ~w(.ts .mts .cts) -> "typescript"
      ext in ~w(.tsx) -> "tsx"
      ext in ~w(.jsx) -> "jsx"
      ext in ~w(.json) -> "json"
      ext in ~w(.yml .yaml) -> "yaml"
      ext in ~w(.toml) -> "toml"
      ext in ~w(.xml .xsl .xsd) -> "xml"
      ext in ~w(.html .htm .heex) -> "html"
      ext in ~w(.css) -> "css"
      ext in ~w(.scss .sass) -> "scss"
      ext in ~w(.md .markdown) -> "markdown"
      ext in ~w(.sh .bash .zsh .fish) -> "bash"
      ext in ~w(.sql) -> "sql"
      ext in ~w(.rs) -> "rust"
      ext in ~w(.go) -> "go"
      ext in ~w(.java) -> "java"
      ext in ~w(.kt .kts) -> "kotlin"
      ext in ~w(.swift) -> "swift"
      ext in ~w(.c .h) -> "c"
      ext in ~w(.cpp .hpp .cc .cxx) -> "cpp"
      ext in ~w(.cs) -> "csharp"
      ext in ~w(.php) -> "php"
      ext in ~w(.lua) -> "lua"
      ext in ~w(.r) -> "r"
      ext in ~w(.vue) -> "vue"
      ext in ~w(.svelte) -> "svelte"
      ext in ~w(.graphql .gql) -> "graphql"
      ext in ~w(.tf .hcl) -> "hcl"
      ext in ~w(.proto) -> "protobuf"
      ext in ~w(.dockerfile) or name == "dockerfile" -> "dockerfile"
      name in ~w(gemfile rakefile guardfile vagrantfile berksfile capfile podfile
                 dangerfile fastfile appfile matchfile pluginfile snapfile
                 thorfile config.ru .pryrc .irbrc .gemrc) -> "ruby"
      name == "brewfile" -> "ruby"
      name == "makefile" -> "makefile"
      name == "procfile" -> "yaml"
      name in ~w(cmakelists.txt) -> "makefile"
      name in ~w(.bashrc .bash_profile .zshrc .zprofile .profile) -> "bash"
      name in ~w(.gitignore .gitattributes .dockerignore .env .env.example) -> "bash"
      true -> nil
    end
  end

  @doc "Check if content looks like binary (has null bytes or high ratio of non-printable chars)."
  @spec binary_content?(String.t()) :: boolean()
  def binary_content?(content) when is_binary(content) do
    sample = binary_part(content, 0, min(byte_size(content), 8192))
    String.contains?(sample, <<0>>)
  end

  defp name_suggests_text?(name) do
    name in ~w(readme license changelog authors contributors todo
               .gitignore .gitattributes .dockerignore .editorconfig
               .env .env.example .tool-versions .ruby-version .node-version
               .nvmrc .python-version procfile)
  end
end
