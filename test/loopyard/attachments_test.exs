defmodule Loopyard.AttachmentsTest do
  use ExUnit.Case, async: true

  alias Loopyard.Attachments
  alias Loopyard.Test.FakeAttachmentWriter

  @png %{path: "shot.png", name: "shot.png", mime: "image/png", size: 84_213}
  @png_bytes <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>
  @log %{
    path: "/workspace/.loopyard/uploads/x-server.log",
    name: "x-server.log",
    mime: "text/plain",
    size: 12
  }

  describe "annotate/2 + parse/1" do
    test "no attachments leaves the text untouched" do
      assert Attachments.annotate("hello", []) == "hello"
      assert Attachments.parse("hello") == {"hello", []}
      assert Attachments.parse(nil) == {"", []}
    end

    test "round-trips text and attachments through one marker line per file" do
      text = Attachments.annotate("Why does this look off?", [@png, @log])

      assert text =~ "Why does this look off?\n\n📎 Attached: shot.png (image/png, 84213 bytes)"

      assert text =~
               "📎 Attached: /workspace/.loopyard/uploads/x-server.log (text/plain, 12 bytes)"

      assert {"Why does this look off?", [png, log]} = Attachments.parse(text)
      assert png == @png
      assert log == @log
    end

    test "attachments alone — no filler text is invented for the human" do
      text = Attachments.annotate("   ", [@png])
      refute text =~ "\n\n"
      assert {"", [@png]} = Attachments.parse(text)
    end

    test "a marker line the agent could read still tells it what to do" do
      assert Attachments.annotate("", [@png]) =~ "open the file to view it"
    end

    test "prose that merely mentions the clip is not parsed as an attachment" do
      text = "I wrote 📎 Attached: in my notes (not, really)"
      assert Attachments.parse(text) == {text, []}
    end
  end

  describe "stored_name/1" do
    test "keeps a recognizable, safe name with the extension" do
      name = Attachments.stored_name("Screen Shot 2026-09-01 at 3.42.11 PM.png")

      assert Regex.match?(
               ~r/^\d{8}T\d{6}-[0-9a-f]{4}-Screen-Shot-2026-09-01-at-3\.42\.11-PM\.png$/,
               name
             )

      assert Attachments.safe_name?(name)
    end

    test "strips directories and weird characters; empty stems become 'file'" do
      assert Attachments.stored_name("../../etc/passwd") =~ ~r/-passwd$/
      assert Attachments.stored_name("???.PNG") =~ ~r/-file\.png$/
      assert Attachments.stored_name("") =~ ~r/-file$/
    end
  end

  describe "volume_path/1" do
    test "only safe basenames resolve, under the uploads dir" do
      assert Attachments.volume_path("20260901T1-ab-shot.png") ==
               {:ok, ".loopyard/uploads/20260901T1-ab-shot.png"}

      assert Attachments.volume_path("../secret") == :error
      assert Attachments.volume_path(".gitignore") == :error
      assert Attachments.volume_path("a/b.png") == :error
    end
  end

  describe "store/2" do
    test "copies every upload into the volume and self-ignores the dir" do
      tmp = Path.join(System.tmp_dir!(), "att-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      src = Path.join(tmp, "upload.tmp")
      File.write!(src, @png_bytes)

      ws = "att-ws-#{System.unique_integer([:positive])}"
      volume = Loopyard.Workspace.volume_name_for(ws)

      assert {:ok, [att]} =
               Attachments.store(ws, [
                 %{path: src, client_name: "shot.png", client_type: "image/png", client_size: 7}
               ])

      assert att.mime == "image/png"
      assert att.size == byte_size(@png_bytes)
      assert att.path == "/workspace/.loopyard/uploads/" <> att.name
      assert att.name =~ ~r/-shot\.png$/

      assert FakeAttachmentWriter.read(volume, att.path) == @png_bytes
      assert FakeAttachmentWriter.read(volume, ".loopyard/uploads/.gitignore") == "*\n"
    end

    test "falls back to the extension for mime and the file for size" do
      tmp = Path.join(System.tmp_dir!(), "att-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      src = Path.join(tmp, "upload.tmp")
      File.write!(src, "abc")

      assert {:ok, [att]} = Attachments.store("att-ws-2", [%{path: src, client_name: "notes.md"}])
      assert att.mime == "text/markdown"
      assert att.size == 3
    end
  end

  describe "prompt_blocks/2" do
    alias Loopyard.Test.FakeVolumeIO

    setup do
      prev = Application.get_env(:loopyard, :volume_reader)
      Application.put_env(:loopyard, :volume_reader, FakeVolumeIO)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:loopyard, :volume_reader, prev),
          else: Application.delete_env(:loopyard, :volume_reader)
      end)

      :ok
    end

    @shot %{
      path: "/workspace/.loopyard/uploads/x-shot.png",
      name: "x-shot.png",
      mime: "image/png",
      size: 16
    }

    test "text goes verbatim, images ride along as base64 image blocks" do
      volume =
        FakeVolumeIO.seed("vol-pb", [{"/workspace/.loopyard/uploads/x-shot.png", @png_bytes}])

      text = Attachments.annotate("look", [@shot, @log])

      assert [
               %{"type" => "text", "text" => ^text},
               %{"type" => "image", "data" => data, "mimeType" => "image/png"}
             ] = Attachments.prompt_blocks(text, %{volume: volume, image?: true})

      assert Base.decode64!(data) == @png_bytes
    end

    test "a file that isn't really an image is never inlined, whatever its label" do
      volume =
        FakeVolumeIO.seed("vol-pb3", [
          {"/workspace/.loopyard/uploads/x-shot.png", "<svg onload=alert(1)>"}
        ])

      text = Attachments.annotate("look", [@shot])

      assert [%{"type" => "text"}] =
               Attachments.prompt_blocks(text, %{volume: volume, image?: true})
    end

    test "only files in the session's uploads dir are read — a typed marker line can't reach elsewhere" do
      volume = FakeVolumeIO.seed("vol-pb4", [{"/workspace/secret.png", @png_bytes}])
      forged = %{@shot | path: "/workspace/secret.png", name: "secret.png"}
      text = Attachments.annotate("look", [forged])

      assert [%{"type" => "text"}] =
               Attachments.prompt_blocks(text, %{volume: volume, image?: true})
    end

    test "the prompt's inline images are capped in total; the rest stay path-only" do
      # Six images whose marker lines each claim 4 MB: five fit a 20 MB budget,
      # the sixth stays path-only.
      four_mb = @png_bytes <> :binary.copy(<<0>>, 4 * 1024 * 1024 - byte_size(@png_bytes))
      files = for i <- 1..6, do: {"/workspace/.loopyard/uploads/x-#{i}.png", four_mb}
      volume = FakeVolumeIO.seed("vol-pb5", files)

      atts =
        for i <- 1..6,
            do: %{
              path: "/workspace/.loopyard/uploads/x-#{i}.png",
              name: "x-#{i}.png",
              mime: "image/png",
              size: 4 * 1024 * 1024
            }

      blocks =
        Attachments.prompt_blocks(Attachments.annotate("", atts), %{volume: volume, image?: true})

      assert Enum.count(blocks, &(&1["type"] == "image")) == 5
    end

    test "a harness without image support, or no volume, gets the lone text block" do
      text = Attachments.annotate("look", [@shot])

      assert [%{"type" => "text"}] =
               Attachments.prompt_blocks(text, %{volume: "v", image?: false})

      assert [%{"type" => "text"}] = Attachments.prompt_blocks(text, %{volume: nil, image?: true})

      assert [%{"type" => "text", "text" => "plain"}] =
               Attachments.prompt_blocks("plain", %{volume: "v", image?: true})
    end

    test "an unreadable or oversize image stays path-only instead of failing the turn" do
      volume = FakeVolumeIO.seed("vol-pb2", [])

      text =
        Attachments.annotate("", [
          @shot,
          %{
            @shot
            | size: 6 * 1024 * 1024,
              path: "/workspace/.loopyard/uploads/big.png",
              name: "big.png"
          }
        ])

      assert [%{"type" => "text"}] =
               Attachments.prompt_blocks(text, %{volume: volume, image?: true})
    end
  end

  describe "container target (the operator)" do
    alias Loopyard.Test.FakeContainerIO

    test "store/2 puts files under <home>/.loopyard/uploads in the container, self-ignored" do
      tmp = Path.join(System.tmp_dir!(), "att-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      src = Path.join(tmp, "upload.tmp")
      File.write!(src, "PNG!")

      target = {:container, "loopyard-ws-brad", "/home/brad"}

      assert {:ok, [att]} =
               Attachments.store(target, [
                 %{path: src, client_name: "shot.png", client_type: "image/png", client_size: 4}
               ])

      assert att.path == "/home/brad/.loopyard/uploads/" <> att.name
      assert FakeContainerIO.read_file("loopyard-ws-brad", att.path) == {:ok, "PNG!"}

      assert FakeContainerIO.read_file(
               "loopyard-ws-brad",
               "/home/brad/.loopyard/uploads/.gitignore"
             ) == {:ok, "*\n"}
    end

    test "prompt_blocks/2 reads the image out of the container when there's no volume" do
      path = "/home/brad/.loopyard/uploads/x-shot.png"
      FakeContainerIO.seed("loopyard-ws-brad", path, @png_bytes)

      text =
        Attachments.annotate("look", [
          %{path: path, name: "x-shot.png", mime: "image/png", size: 16}
        ])

      ctx = %{volume: nil, container: "loopyard-ws-brad", cwd: "/home/brad", image?: true}

      assert [%{"type" => "text"}, %{"type" => "image", "data" => data}] =
               Attachments.prompt_blocks(text, ctx)

      assert Base.decode64!(data) == @png_bytes

      # Confined to that home's uploads dir: a marker naming ~/.ssh reads nothing.
      FakeContainerIO.seed("loopyard-ws-brad", "/home/brad/.ssh/id_rsa", @png_bytes)

      forged =
        Attachments.annotate("", [
          %{path: "/home/brad/.ssh/id_rsa", name: "id_rsa", mime: "image/png", size: 16}
        ])

      assert [%{"type" => "text"}] = Attachments.prompt_blocks(forged, ctx)
    end

    test "url/2 with no workspace is the operator's attachment route; container_path guards the name" do
      assert Attachments.url(nil, "x-shot.png") == "/operator/attachments/x-shot.png"

      assert Attachments.container_path("/home/brad", "x-shot.png") ==
               {:ok, "/home/brad/.loopyard/uploads/x-shot.png"}

      assert Attachments.container_path("/home/brad", "../.ssh/id_rsa") == :error
    end
  end

  test "display_name/1 drops the uniqueness prefix a human never typed" do
    assert Attachments.display_name("20260902T061913-9608-riddle.png") == "riddle.png"

    assert Attachments.display_name(%{name: "20260902T061913-9608-Screen-Shot.png"}) ==
             "Screen-Shot.png"

    assert Attachments.display_name("plain.png") == "plain.png"
  end

  test "sniff_image/1 and heic?/1 read magic numbers" do
    assert Attachments.sniff_image(@png_bytes) == "image/png"
    assert Attachments.sniff_image(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 0>>) == "image/jpeg"
    assert Attachments.sniff_image("GIF89a....") == "image/gif"
    assert Attachments.sniff_image("RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8 ") == "image/webp"
    assert Attachments.sniff_image("<svg xmlns=") == nil
    assert Attachments.sniff_image("") == nil
    assert Attachments.heic?(<<0, 0, 0, 24, "ftypheic", 0, 0>>)
    refute Attachments.heic?(@png_bytes)
  end

  test "the stored type is what the bytes are, not the browser's label" do
    tmp = Path.join(System.tmp_dir!(), "att-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    jpg = Path.join(tmp, "upload.tmp")
    File.write!(jpg, <<0xFF, 0xD8, 0xFF, 0xE0>> <> "not really a jpeg body")

    # Labelled png by the client, actually JPEG bytes: stored as JPEG.
    assert {:ok, [att]} =
             Attachments.store("att-ws-3", [
               %{path: jpg, client_name: "shot.png", client_type: "image/png"}
             ])

    assert att.mime == "image/jpeg"
  end

  test "a HEIC upload is stored as a JPEG the model can see (macOS sips)" do
    sips = System.find_executable("sips")

    if sips do
      tmp = Path.join(System.tmp_dir!(), "att-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      png = Path.join(tmp, "dot.png")

      File.write!(
        png,
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        )
      )

      heic = Path.join(tmp, "photo.heic")

      {_, 0} =
        System.cmd(sips, ["-s", "format", "heic", png, "--out", heic], stderr_to_stdout: true)

      assert Attachments.heic?(File.read!(heic))

      assert {:ok, [att]} =
               Attachments.store("att-ws-heic", [
                 %{path: heic, client_name: "IMG_0001.HEIC", client_type: "image/heic"}
               ])

      assert att.mime == "image/jpeg"
      assert att.name =~ ~r/-IMG_0001\.jpg$/
      volume = Loopyard.Workspace.volume_name_for("att-ws-heic")
      jpg = FakeAttachmentWriter.read(volume, att.path)
      assert Attachments.sniff_image(jpg) == "image/jpeg"
      # The marker's size is the JPEG's, not the HEIC's.
      assert att.size == byte_size(jpg)
      assert File.exists?(heic)
    end
  end

  test "image?/1 is by mime, and svg is not inlined" do
    assert Attachments.image?(@png)
    refute Attachments.image?(@log)
    refute Attachments.image?(%{mime: "image/svg+xml"})
  end
end
