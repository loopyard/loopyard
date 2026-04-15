defmodule BoomLooperWeb.Live.WorkspaceLive.Components.Viewers.Syntax do
  @moduledoc """
  Server-side syntax highlighting via Makeup + MakeupSyntect.

  This module is the only place that touches Makeup. The text viewer calls
  `highlight/2` and gets back a Phoenix.HTML.safe tuple. Everything else
  (language detection, file type detection) lives in FileType.

  MakeupSyntect wraps Rust's syntect via a NIF. It supports 200+ languages
  but uses its own API (not the standard Makeup lexer interface), so we
  call MakeupSyntect.tokenize/2 directly and format with Makeup's HTML
  formatter.
  """

  @doc """
  Highlight a line of code. Returns `{:safe, html}` for highlighted output,
  or the original string (auto-escaped by HEEx) if highlighting fails or
  the language isn't supported.
  """
  def highlight(line, nil), do: line
  def highlight("", _language), do: Phoenix.HTML.raw("&nbsp;")

  def highlight(line, language) do
    case syntect_name(language) do
      nil -> line
      syntect_lang ->
        try do
          tokens = MakeupSyntect.tokenize(line, language: syntect_lang)

          html =
            Makeup.Formatters.HTML.HTMLFormatter.format_as_iolist(tokens)
            |> IO.iodata_to_binary()
            |> strip_wrapper()

          Phoenix.HTML.raw(html)
        rescue
          _ -> line
        end
    end
  end

  # Strip Makeup's <pre><code>...</code></pre> wrapper — the viewer
  # handles its own layout (table with line numbers).
  defp strip_wrapper(html) do
    html
    |> String.replace(~r/<pre[^>]*><code[^>]*>/, "")
    |> String.replace(~r/<\/code><\/pre>/, "")
    |> String.trim()
  end

  # Map FileType language strings to MakeupSyntect's full language names.
  # MakeupSyntect uses syntect's built-in syntax definitions which expect
  # specific capitalized names. Run MakeupSyntect.supported_syntaxes() to
  # see all available.
  @syntect_names %{
    "elixir" => "Elixir",
    "erlang" => "Erlang",
    "ruby" => "Ruby",
    "python" => "Python",
    "javascript" => "JavaScript",
    "typescript" => "TypeScript",
    "tsx" => "TypeScript",
    "jsx" => "JavaScript",
    "html" => "HTML",
    "css" => "CSS",
    "scss" => "SCSS",
    "json" => "JSON",
    "yaml" => "YAML",
    "markdown" => "Markdown",
    "bash" => "Bourne Again Shell (bash)",
    "shell" => "Bourne Again Shell (bash)",
    "sql" => "SQL",
    "go" => "Go",
    "rust" => "Rust",
    "java" => "Java",
    "kotlin" => "Kotlin",
    "swift" => "Swift",
    "c" => "C",
    "cpp" => "C++",
    "csharp" => "C#",
    "php" => "PHP",
    "lua" => "Lua",
    "r" => "R",
    "xml" => "XML",
    "toml" => "TOML",
    "dockerfile" => "Dockerfile",
    "makefile" => "Makefile",
    "hcl" => "Terraform",
    "graphql" => "GraphQL",
    "protobuf" => "Protocol Buffers"
  }

  defp syntect_name(language) do
    Map.get(@syntect_names, language)
  end
end
