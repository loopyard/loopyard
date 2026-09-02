defmodule Loopyard.AttachmentsTest do
  use ExUnit.Case, async: true

  alias Loopyard.Attachments
  alias Loopyard.Test.FakeAttachmentWriter

  @png %{path: "shot.png", name: "shot.png", mime: "image/png", size: 84_213}
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
      File.write!(src, <<137, 80, 78, 71, 1, 2, 3>>)

      ws = "att-ws-#{System.unique_integer([:positive])}"
      volume = Loopyard.Workspace.volume_name_for(ws)

      assert {:ok, [att]} =
               Attachments.store(ws, [
                 %{path: src, client_name: "shot.png", client_type: "image/png", client_size: 7}
               ])

      assert att.mime == "image/png"
      assert att.size == 7
      assert att.path == "/workspace/.loopyard/uploads/" <> att.name
      assert att.name =~ ~r/-shot\.png$/

      assert FakeAttachmentWriter.read(volume, att.path) == <<137, 80, 78, 71, 1, 2, 3>>
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
      size: 4
    }

    test "text goes verbatim, images ride along as base64 image blocks" do
      volume = FakeVolumeIO.seed("vol-pb", [{"/workspace/.loopyard/uploads/x-shot.png", "PNG!"}])
      text = Attachments.annotate("look", [@shot, @log])

      assert [
               %{"type" => "text", "text" => ^text},
               %{"type" => "image", "data" => data, "mimeType" => "image/png"}
             ] = Attachments.prompt_blocks(text, %{volume: volume, image?: true})

      assert Base.decode64!(data) == "PNG!"
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
          %{@shot | size: 6 * 1024 * 1024, path: "/workspace/.loopyard/uploads/big.png"}
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
      FakeContainerIO.seed("loopyard-ws-brad", path, "PNG!")

      text =
        Attachments.annotate("look", [
          %{path: path, name: "x-shot.png", mime: "image/png", size: 4}
        ])

      assert [%{"type" => "text"}, %{"type" => "image", "data" => data}] =
               Attachments.prompt_blocks(text, %{
                 volume: nil,
                 container: "loopyard-ws-brad",
                 image?: true
               })

      assert Base.decode64!(data) == "PNG!"
    end

    test "url/2 with no workspace is the operator's attachment route; container_path guards the name" do
      assert Attachments.url(nil, "x-shot.png") == "/operator/attachments/x-shot.png"

      assert Attachments.container_path("/home/brad", "x-shot.png") ==
               {:ok, "/home/brad/.loopyard/uploads/x-shot.png"}

      assert Attachments.container_path("/home/brad", "../.ssh/id_rsa") == :error
    end
  end

  test "image?/1 is by mime, and svg is not inlined" do
    assert Attachments.image?(@png)
    refute Attachments.image?(@log)
    refute Attachments.image?(%{mime: "image/svg+xml"})
  end
end
