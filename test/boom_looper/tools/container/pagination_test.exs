defmodule BoomLooper.Tools.Container.PaginationTest do
  use ExUnit.Case, async: true

  alias BoomLooper.Tools.Container.Pagination

  describe "paginate/2" do
    test "returns all items when under limit" do
      {page, footer} = Pagination.paginate(~w(a b c), limit: 10)
      assert page == ~w(a b c)
      assert footer == nil
    end

    test "truncates to limit and shows footer" do
      items = Enum.map(1..100, &"item-#{&1}")
      {page, footer} = Pagination.paginate(items, limit: 10)
      assert length(page) == 10
      assert hd(page) == "item-1"
      assert footer =~ "first 10 of 100+"
      assert footer =~ "offset=10"
    end

    test "offset skips items" do
      items = Enum.map(1..20, &"item-#{&1}")
      {page, footer} = Pagination.paginate(items, limit: 5, offset: 10)
      assert hd(page) == "item-11"
      assert length(page) == 5
      assert footer =~ "11–15"
    end

    test "offset past end returns empty with helpful message" do
      {page, footer} = Pagination.paginate(~w(a b c), limit: 10, offset: 100)
      assert page == []
      assert footer =~ "no results at offset 100"
    end

    test "last page has no 'next page' hint" do
      items = Enum.map(1..15, &"item-#{&1}")
      {page, footer} = Pagination.paginate(items, limit: 10, offset: 10)
      assert length(page) == 5
      assert footer =~ "11–15 of 15"
      refute footer =~ "next page"
    end

    test "defaults to 50 limit" do
      items = Enum.map(1..100, &"x-#{&1}")
      {page, _} = Pagination.paginate(items)
      assert length(page) == 50
    end

    test "clamps limit to max 500" do
      items = Enum.map(1..1000, &"x-#{&1}")
      {page, _} = Pagination.paginate(items, limit: 9999)
      assert length(page) == 500
    end
  end

  describe "cap/1" do
    test "short text passes through" do
      assert Pagination.cap("hello") == "hello"
    end

    test "long text is truncated with message" do
      long = String.duplicate("x", 10_000)
      result = Pagination.cap(long, 100)
      assert String.length(result) < 300
      assert result =~ "10000 bytes total"
      assert result =~ "Narrow your query"
    end
  end

  describe "format_lines/2" do
    test "joins and paginates lines" do
      lines = Enum.map(1..10, &"line #{&1}")
      result = Pagination.format_lines(lines, limit: 5)
      assert result =~ "line 1"
      assert result =~ "line 5"
      refute result =~ "line 6"
      assert result =~ "first 5 of 10+"
    end

    test "caps long lines" do
      lines = [String.duplicate("x", 500)]
      result = Pagination.format_lines(lines, max_line_chars: 50)
      # Line should be ~51 chars (50 + ellipsis) not 500
      first_line = result |> String.split("\n") |> hd()
      assert String.length(first_line) <= 52
      assert first_line =~ "…"
    end

    test "empty list" do
      result = Pagination.format_lines([])
      assert result == ""
    end
  end
end
