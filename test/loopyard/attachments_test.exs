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

  test "image?/1 is by mime, and svg is not inlined" do
    assert Attachments.image?(@png)
    refute Attachments.image?(@log)
    refute Attachments.image?(%{mime: "image/svg+xml"})
  end
end
