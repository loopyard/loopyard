defmodule LoopyardWeb.Live.WorkspaceLive.Components.Viewers.ImageViewer do
  @moduledoc "Renders image file content as a base64-encoded inline image."
  use Phoenix.Component

  attr :path, :string, required: true
  attr :content, :string, required: true

  def image_viewer(assigns) do
    ext = assigns.path |> Path.extname() |> String.downcase() |> String.trim_leading(".")
    mime = mime_type(ext)
    base64 = Base.encode64(assigns.content)
    assigns = assign(assigns, :data_uri, "data:#{mime};base64,#{base64}")

    ~H"""
    <div class="flex flex-col items-center p-6 max-h-[60vh] overflow-auto">
      <img
        src={@data_uri}
        alt={Path.basename(@path)}
        class="max-w-full max-h-[50vh] object-contain rounded border border-zinc-200 dark:border-zinc-700"
      />
      <span class="mt-2 text-xs text-zinc-400 dark:text-zinc-500">{Path.basename(@path)}</span>
    </div>
    """
  end

  defp mime_type("svg"), do: "image/svg+xml"
  defp mime_type("png"), do: "image/png"
  defp mime_type("jpg"), do: "image/jpeg"
  defp mime_type("jpeg"), do: "image/jpeg"
  defp mime_type("gif"), do: "image/gif"
  defp mime_type("webp"), do: "image/webp"
  defp mime_type("ico"), do: "image/x-icon"
  defp mime_type("bmp"), do: "image/bmp"
  defp mime_type(_), do: "application/octet-stream"
end
