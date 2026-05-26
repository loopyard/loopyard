defmodule Aural.SignalsTest do
  use ExUnit.Case, async: true

  alias Aural.Signals

  describe "kinds/0" do
    test "returns the three supported chimes" do
      assert Enum.sort(Signals.kinds()) == ["alert", "attention", "done"]
    end
  end

  describe "chime_lifetime_samples/1" do
    test "converts seconds to samples at the sample rate" do
      # 5.0 s × 48 000 Hz = 240 000 samples
      assert Signals.chime_lifetime_samples("done") == 240_000
      assert Signals.chime_lifetime_samples("attention") == 144_000
      assert Signals.chime_lifetime_samples("alert") == 86_400
    end

    test "returns 0 for unknown kinds" do
      assert Signals.chime_lifetime_samples("nope") == 0
    end
  end

  describe "chime_sample/2 — boundary conditions" do
    test "is exactly 0 at and after the lifetime" do
      for kind <- Signals.kinds() do
        secs = Signals.chime_lifetime_samples(kind) / 48_000
        assert Signals.chime_sample(kind, secs) == 0.0
        assert Signals.chime_sample(kind, secs + 1.0) == 0.0
      end
    end

    test "is exactly 0 at t=0 (5ms attack hasn't ramped yet for bells)" do
      # bell_envelope multiplies by min(t/0.005, 1.0), so at t=0
      # the attack term is 0.
      assert Signals.chime_sample("done", 0.0) == 0.0
      assert Signals.chime_sample("alert", 0.0) == 0.0
    end

    test "returns 0 for unknown kind" do
      assert Signals.chime_sample("nope", 0.5) == 0.0
    end

    test "returns 0 for non-binary or negative t" do
      assert Signals.chime_sample("done", -1.0) == 0.0
      assert Signals.chime_sample(:done, 0.5) == 0.0
    end
  end

  describe "chime_sample/2 — envelope shape" do
    test "bell chime peaks shortly after attack, then decays" do
      # "done" has 5ms attack + tau=2.0 decay. Peak should be near
      # t=5ms (right after attack completes); at t=1s amplitude
      # should be roughly env_factor * exp(-1/2) ≈ 0.6 of peak.
      peak = Signals.chime_sample("done", 0.005)
      mid = Signals.chime_sample("done", 1.0)
      late = Signals.chime_sample("done", 4.0)

      # Each progressively smaller in absolute value at the same
      # sine phase. Compare RMS-ish via abs.
      assert abs(peak) > 0.0
      assert abs(late) < abs(peak)
      # Use coarse-grained envelope comparison by sampling several
      # phases near each time and taking max-abs.
      assert envelope_strength("done", 0.005) > envelope_strength("done", 1.0)
      assert envelope_strength("done", 1.0) > envelope_strength("done", 4.0)
    end

    test "tail fadeout brings amplitude to zero in last 0.3s of lifetime" do
      # "done" lifetime = 5.0s, fadeout starts at 4.7s.
      strong = envelope_strength("done", 4.6)
      faded = envelope_strength("done", 4.95)

      assert strong > 0.0
      # Fadeout brings the sample close to zero (smoothstep × residual
      # exp decay), well below the un-faded amplitude.
      assert faded < strong / 5
    end

    test "bow envelope sustains during the sustain window" do
      # "attention" has 0.25s attack + 0.5s sustain + 1.5s release;
      # sustain region is [0.25, 0.75]. Compare a sample at 0.5s
      # (mid-sustain) to a sample at 1.5s (mid-release).
      sustain = envelope_strength("attention", 0.5)
      release_mid = envelope_strength("attention", 1.5)

      assert sustain > release_mid
    end
  end

  # Sample the chime over a ~5 ms window around `t` and return the
  # peak absolute amplitude. Avoids picking the unfortunate zero of
  # a sine phase as "amplitude". Sample density covers ≥2 full
  # cycles of the highest "done" voice (783.99 Hz → 1.28 ms
  # period), so we always hit a near-peak phase regardless of where
  # `t` lands.
  defp envelope_strength(kind, t) do
    for offset <- 0..99 do
      Signals.chime_sample(kind, t + offset * 0.00005) |> abs()
    end
    |> Enum.max()
  end
end
