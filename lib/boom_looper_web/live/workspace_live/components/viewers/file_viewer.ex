defmodule BoomLooperWeb.Live.WorkspaceLive.Components.Viewers.FileViewer do
  @moduledoc """
  Dispatches to the right viewer based on file type.

  Usage in a parent component:

      <.file_viewer path={@file_path} content={@file_content} />
  """
  use Phoenix.Component

  alias BoomLooperWeb.Live.WorkspaceLive.Components.Viewers.{
    FileType,
    TextViewer,
    ImageViewer,
    BinaryViewer
  }

  attr :path, :string, required: true
  attr :content, :string, required: true
  attr :size, :integer, default: nil
  attr :volume_name, :string, default: nil

  def file_viewer(assigns) do
    file_type = FileType.detect(assigns.path)

    # Override detected type if content looks binary
    file_type =
      if file_type in [:text, :unknown] && FileType.binary_content?(assigns.content) do
        :binary
      else
        file_type
      end

    assigns = assign(assigns, :file_type, file_type)

    ~H"""
    <TextViewer.text_viewer
      :if={@file_type == :text}
      path={@path}
      content={@content}
      volume_name={@volume_name}
    />
    <ImageViewer.image_viewer :if={@file_type == :image} path={@path} content={@content} />
    <BinaryViewer.binary_viewer :if={@file_type in [:binary, :unknown]} path={@path} size={@size} />
    """
  end
end
