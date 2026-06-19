defmodule LoopyardWeb.Live.WorkspaceLive.Components.Viewers.Syntax do
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
      nil ->
        line

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

  @doc """
  Highlight a multi-line block in ONE tokenize pass, returning a list of
  `{:safe, html}` (or `"&nbsp;"`) — one entry per line, in order. Same
  per-line output shape as calling `highlight/2` on each line, but ~15x
  faster: `MakeupSyntect.tokenize/2` has a large fixed per-call NIF cost
  (~18ms), so a 70-line block is 70× that when highlighted line-by-line.

  Returns `nil` when the language is unsupported or highlighting fails —
  the signal for callers to fall back to plain (unhighlighted) lines.
  The returned list length always equals `length(String.split(text, "\\n"))`,
  so callers can map it 1:1 onto their own line splitting.
  """
  def highlight_lines(text, language) when is_binary(text) do
    case syntect_name(language) do
      nil ->
        nil

      syntect_lang ->
        try do
          MakeupSyntect.tokenize(text, language: syntect_lang)
          |> tokens_to_lines()
          |> Enum.map(&format_line/1)
        rescue
          _ -> nil
        end
    end
  end

  def highlight_lines(_text, _language), do: nil

  # Group a flat token stream into per-line token lists, splitting any
  # token whose value spans a newline. One `:newline` marker is emitted
  # per "\n" character, so the line count matches String.split/2 exactly.
  defp tokens_to_lines(tokens) do
    segments =
      Enum.flat_map(tokens, fn {ttype, meta, value} ->
        value
        |> List.wrap()
        |> IO.iodata_to_binary()
        |> String.split("\n")
        |> Enum.map(fn part -> {ttype, meta, part} end)
        |> Enum.intersperse(:newline)
      end)

    {lines, current} =
      Enum.reduce(segments, {[], []}, fn
        :newline, {lines, current} -> {[Enum.reverse(current) | lines], []}
        seg, {lines, current} -> {lines, [seg | current]}
      end)

    Enum.reverse([Enum.reverse(current) | lines])
  end

  defp format_line(tokens) do
    case Enum.reject(tokens, fn {_t, _m, v} -> v == "" end) do
      [] ->
        Phoenix.HTML.raw("&nbsp;")

      toks ->
        Makeup.Formatters.HTML.HTMLFormatter.format_as_iolist(toks)
        |> IO.iodata_to_binary()
        |> strip_wrapper()
        |> Phoenix.HTML.raw()
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
