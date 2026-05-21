defmodule Loopyard.Ambient.SynthTest do
  use ExUnit.Case, async: true

  alias Loopyard.Ambient.Synth

  describe "sample_rate/0" do
    test "is 48000Hz" do
      assert Synth.sample_rate() == 48_000
    end
  end

  describe "track_names/0 + resolve/1" do
    test "lists all known tracks" do
      names = Synth.track_names()
      assert :serene in names
      assert :nocturne in names
      assert :pulse in names
    end

    test "resolves by atom" do
      assert Synth.resolve(:serene) == Loopyard.Ambient.Tracks.Serene
      assert Synth.resolve(:nocturne) == Loopyard.Ambient.Tracks.Nocturne
    end

    test "resolves by string for known tracks" do
      assert Synth.resolve("pulse") == Loopyard.Ambient.Tracks.Pulse
    end

    test "returns nil for unknown names" do
      assert Synth.resolve(:not_a_track) == nil
      assert Synth.resolve("definitely-not-a-track-xyz") == nil
      assert Synth.resolve(123) == nil
    end
  end

  describe "render_chunk/3" do
    test "produces 2 bytes per sample (16-bit PCM)" do
      assert byte_size(Synth.render_chunk(:serene, 0, 100)) == 200
      assert byte_size(Synth.render_chunk(:serene, 0, 4_800)) == 9_600
    end

    test "produces zero-length binary for zero samples" do
      assert Synth.render_chunk(:serene, 0, 0) == <<>>
    end

    test "all samples are signed 16-bit values for every track" do
      for track <- Synth.track_names() do
        chunk = Synth.render_chunk(track, 0, 1_000)
        samples = for <<s::little-signed-16 <- chunk>>, do: s

        assert length(samples) == 1_000
        Enum.each(samples, fn s ->
          assert s >= -32_768 and s <= 32_767,
                 "track #{track}: sample #{s} out of int16 range"
        end)
      end
    end

    test "renders deterministically for the same input" do
      a = Synth.render_chunk(:serene, 0, 256)
      b = Synth.render_chunk(:serene, 0, 256)
      assert a == b
    end

    test "different start_t produces different output" do
      a = Synth.render_chunk(:serene, 0, 256)
      b = Synth.render_chunk(:serene, 10_000, 256)
      refute a == b
    end

    test "different tracks produce different output for the same time range" do
      outputs = Enum.map(Synth.track_names(), &Synth.render_chunk(&1, 0, 512))

      assert MapSet.new(outputs) |> MapSet.size() == length(Synth.track_names()),
             "two or more tracks produced byte-identical output"
    end

    test "consecutive chunks join continuously at the boundary" do
      whole = Synth.render_chunk(:serene, 0, 4_800)
      first_half = Synth.render_chunk(:serene, 0, 2_400)
      second_half = Synth.render_chunk(:serene, 2_400, 2_400)
      assert first_half <> second_half == whole
    end

    test "no short-cycle repeat (chord pool is hash-driven)" do
      for track <- Synth.track_names() do
        a = Synth.render_chunk(track, 0, 256)
        b = Synth.render_chunk(track, 48_000 * 60, 256)
        refute a == b, "track #{track} repeated after 60s — chord pool may be too small"
      end
    end

    test "produces non-silent output (not all zeros) for every track" do
      for track <- Synth.track_names() do
        chunk = Synth.render_chunk(track, 0, 4_800)
        samples = for <<s::little-signed-16 <- chunk>>, do: s

        assert Enum.any?(samples, &(&1 != 0)),
               "track #{track} produced only zeros — silent output"
      end
    end

    test "amplitude stays bounded — no track approaches clipping" do
      for track <- Synth.track_names() do
        chunk = Synth.render_chunk(track, 11 * 48_000, 4_800)
        samples = for <<s::little-signed-16 <- chunk>>, do: s
        max_abs = samples |> Enum.map(&abs/1) |> Enum.max()

        assert max_abs < 30_000,
               "track #{track} approaching clipping (max abs sample = #{max_abs})"
      end
    end

    test "unknown track falls back to Serene" do
      a = Synth.render_chunk(:unknown_track, 0, 256)
      b = Synth.render_chunk(:serene, 0, 256)
      assert a == b
    end
  end
end
