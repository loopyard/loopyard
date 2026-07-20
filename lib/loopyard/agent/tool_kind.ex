defmodule Loopyard.Agent.ToolKind do
  @moduledoc """
  Maps a harness tool NAME to a neutral, harness-agnostic KIND that the UI
  renders by — the seam that keeps the pluggable-harness door open.

  The presentation layer must classify tools by KIND, never by matching raw
  names, so a NEW harness (ours or a third party) plugs in without touching the
  UI: it either sets `kind` on its `%Loopyard.Agent.Event.ToolCall{}` directly,
  or names its tools something this classifier already recognizes. This module
  is the ONE place tool-name vocabulary is known.

  Recognized vocabularies today:

    * Claude Code NATIVE tools (the in-container ACP harness): `Bash`, `Read`,
      `Grep`, `Edit`, `MultiEdit`, `Write`, …
    * Loopyard MCP tools (the in-process path): `mcp__loopyard-container__exec`,
      `…__git`, `…__read_file`, `…__grep`, `…__edit`, `…__write_file`, …

  Kinds:

    * `:command` — a shell command; renders as the console box (command title +
      output + exit status).
    * `:read`    — a file read; renders as the syntax-highlighted file card.
    * `:grep`    — a search; renders as the match list.
    * `:edit`    — an edit; renders the diff inline on the call.
    * `:write`   — a file write (category tint only).
    * `:generic` — anything else; the plain collapsible output.
  """

  @type t :: :command | :read | :grep | :edit | :write | :generic

  @doc "Neutral kind for a tool name. Unknown names → `:generic` (graceful)."
  @spec classify(String.t() | nil) :: t()
  def classify(name) when is_binary(name) do
    cond do
      command?(name) -> :command
      name == "Read" or String.ends_with?(name, "__read_file") -> :read
      name == "Grep" or String.ends_with?(name, "__grep") -> :grep
      edit?(name) -> :edit
      name == "Write" or String.ends_with?(name, "__write_file") -> :write
      true -> :generic
    end
  end

  def classify(_), do: :generic

  @doc "True when the tool is a shell command (`:command` kind)."
  @spec command?(String.t()) :: boolean()
  def command?("Bash"), do: true

  def command?(name) when is_binary(name),
    do:
      String.ends_with?(name, "__exec") or String.ends_with?(name, "__docker_compose") or
        String.ends_with?(name, "__git")

  def command?(_), do: false

  @doc "True when the tool is an edit (`:edit` kind)."
  @spec edit?(String.t()) :: boolean()
  def edit?(name) when is_binary(name),
    do:
      name in ["Edit", "MultiEdit"] or String.ends_with?(name, "__edit") or
        String.ends_with?(name, "__multi_edit")

  def edit?(_), do: false
end
