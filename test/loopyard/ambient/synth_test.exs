defmodule Loopyard.Ambient.SynthTest do
  use ExUnit.Case, async: true

  alias Loopyard.Ambient.Synth

  describe "sample_rate/0" do
    test "is 48000Hz" do
      assert Synth.sample_rate() == 48_000
    end
  end

  describe "render_chunk/2" do
    test "produces 2 bytes per sample (16-bit PCM)" do
      assert byte_size(Synth.render_chunk(0, 100)) == 200
      assert byte_size(Synth.render_chunk(0, 4_800)) == 9_600
    end

    test "produces zero-length binary for zero samples" do
      assert Synth.render_chunk(0, 0) == <<>>
    end

    test "all samples are signed 16-bit values" do
      chunk = Synth.render_chunk(0, 1_000)
      samples = for <<s::little-signed-16 <- chunk>>, do: s

      assert length(samples) == 1_000
      Enum.each(samples, fn s ->
        assert s >= -32_768 and s <= 32_767, "sample #{s} out of int16 range"
      end)
    end

    test "renders deterministically for the same input" do
      a = Synth.render_chunk(0, 256)
      b = Synth.render_chunk(0, 256)
      assert a == b
    end

    test "different start_t produces different output (synth is time-dependent)" do
      a = Synth.render_chunk(0, 256)
      b = Synth.render_chunk(10_000, 256)
      refute a == b
    end

    test "consecutive chunks join continuously at the boundary" do
      # Render the first 4800 samples as one chunk, and the same range
      # as two contiguous 2400-sample chunks. The bytes must match —
      # samples are a pure function of their absolute index.
      whole = Synth.render_chunk(0, 4_800)
      first_half = Synth.render_chunk(0, 2_400)
      second_half = Synth.render_chunk(2_400, 2_400)
      assert first_half <> second_half == whole
    end

    test "does not loop on a short cycle (chord pool is hash-driven)" do
      # The synth picks chords via :erlang.phash2(slot) mod pool_size.
      # Two slots far apart should produce different output (very
      # high probability). The previous synth had a 48-second cycle;
      # the current one shouldn't repeat in any audible window.
      a = Synth.render_chunk(0, 256)
      b = Synth.render_chunk(48_000 * 60, 256)
      refute a == b
    end

    test "produces non-silent output (not all zeros)" do
      chunk = Synth.render_chunk(0, 4_800)
      samples = for <<s::little-signed-16 <- chunk>>, do: s
      assert Enum.any?(samples, &(&1 != 0)), "synth produced only zeros — silent output"
    end

    test "amplitude stays bounded (sample_at clamps to [-1, 1])" do
      # Render across a chord transition where pad + bass amplitudes
      # peak. No sample should hit the int16 edges from clipping.
      chunk = Synth.render_chunk(11 * 48_000, 4_800)
      samples = for <<s::little-signed-16 <- chunk>>, do: s
      max_abs = samples |> Enum.map(&abs/1) |> Enum.max()
      # We expect well under the int16 max — pad_gain ~0.3 + bass_gain
      # 0.18 = ~0.48 peak amplitude * 32_767 ≈ 15_700.
      assert max_abs < 30_000,
             "synth approaching clipping (max abs sample = #{max_abs})"
    end
  end
end
