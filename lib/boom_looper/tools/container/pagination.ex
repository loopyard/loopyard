defmodule BoomLooper.Tools.Container.Pagination do
  @moduledoc """
  Shared output capping and pagination for MCP tools that can return
  large result sets.

  Tools call `paginate/2` for list results (grep matches, glob paths)
  or `cap/1` for raw text (git output, exec output). Both return a
  bounded result + a footer telling the agent how to get more.

  The prompt teaches agents: "some tools paginate — look for the
  footer to get the next page or refine your query."
  """

  @default_limit 50
  @max_limit 500
  @max_chars 8_000

  @doc """
  Paginate a list of items. Returns `{page_items, footer_string}`.

  Options (typically passed straight from tool params):
    * `:limit` — max items per page (default #{@default_limit}, max #{@max_limit})
    * `:offset` — skip this many items (default 0)
  """
  def paginate(items, opts \\ []) do
    limit = (opts[:limit] || @default_limit) |> min(@max_limit) |> max(1)
    offset = (opts[:offset] || 0) |> max(0)

    total = length(items)
    page = Enum.slice(items, offset, limit)
    shown = length(page)
    has_more = total > offset + limit

    footer =
      cond do
        shown == 0 && offset > 0 ->
          "(no results at offset #{offset} — only #{total} total)"

        has_more && offset > 0 ->
          "(showing #{offset + 1}–#{offset + shown} of #{total}+. Use offset=#{offset + limit} for next page)"

        has_more ->
          "(showing first #{shown} of #{total}+. Use offset=#{limit} for next page)"

        offset > 0 ->
          "(showing #{offset + 1}–#{offset + shown} of #{total})"

        true ->
          nil
      end

    {page, footer}
  end

  @doc """
  Cap a text string to `@max_chars`. Returns the (possibly truncated)
  string with a footer if truncated.
  """
  def cap(text, max_chars \\ @max_chars) do
    if byte_size(text) <= max_chars do
      text
    else
      truncated = String.slice(text, 0, max_chars)
      total = byte_size(text)

      truncated <>
        "\n\n... (#{total} bytes total, showing first #{max_chars}. Narrow your query for more targeted results.)"
    end
  end

  @doc """
  Cap each line in a list to `max_line_chars`, then join and cap the
  total. Returns the final string with pagination footer appended.
  """
  def format_lines(lines, opts \\ []) do
    max_line = opts[:max_line_chars] || 200

    capped_lines =
      Enum.map(lines, fn line ->
        if String.length(line) > max_line do
          String.slice(line, 0, max_line) <> "…"
        else
          line
        end
      end)

    {page, footer} = paginate(capped_lines, opts)

    result = Enum.join(page, "\n")
    result = cap(result)

    if footer do
      result <> "\n\n" <> footer
    else
      result
    end
  end
end
