module Harness
  module Worldgen
    # Deterministic 2D value noise. Same seed + same (x, y) → same value.
    # Bilinear interpolation between integer grid points with hermite smoothing
    # to remove tearing. Pure Ruby, no gem dependency. Returns floats in [0, 1].
    #
    # Octave summing (FBM) is supported for fractal detail; v1 uses one octave
    # for coarse biome regions.
    class Noise
      def initialize(seed:)
        @seed = seed.to_i & 0xFFFFFFFF
      end

      def at(x, y, octaves: 1, persistence: 0.5)
        total      = 0.0
        amplitude  = 1.0
        frequency  = 1.0
        max_value  = 0.0
        octaves.times do
          total += sample_octave(x * frequency, y * frequency) * amplitude
          max_value += amplitude
          amplitude *= persistence
          frequency *= 2.0
        end
        total / max_value
      end

      private

      def sample_octave(x, y)
        x0 = x.floor
        y0 = y.floor
        sx = smooth(x - x0)
        sy = smooth(y - y0)

        a = grid_value(x0,     y0)
        b = grid_value(x0 + 1, y0)
        c = grid_value(x0,     y0 + 1)
        d = grid_value(x0 + 1, y0 + 1)

        ab = a + sx * (b - a)
        cd = c + sx * (d - c)
        ab + sy * (cd - ab)
      end

      def smooth(t)
        t * t * (3.0 - 2.0 * t)
      end

      def grid_value(xi, yi)
        h = ((xi * 374761393) ^ (yi * 668265263) ^ (@seed * 1274126177)) & 0xFFFFFFFF
        h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
        h = (h ^ (h >> 16)) & 0xFFFFFFFF
        (h & 0xFFFFFF) / 16_777_216.0
      end
    end
  end
end
