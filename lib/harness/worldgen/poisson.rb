module Harness
  module Worldgen
    # Rejection-sampling poisson-disk on a square grid. Plenty fast for v1
    # (15 cities on 100×100). Bridson's algorithm is more efficient at
    # density but isn't needed yet. Deterministic given the seed.
    class Poisson
      def initialize(size:, seed:, max_attempts_per_point: 100)
        @size    = size.to_f
        @rng     = Random.new(seed.to_i & 0xFFFFFFFF)
        @max_per = max_attempts_per_point
      end

      # Returns up to `count` points [x, y] with each pair separated by at
      # least `min_dist`. May return fewer if the grid saturates.
      def sample(count:, min_dist:)
        points = []
        budget = count * @max_per
        while points.size < count && budget > 0
          budget -= 1
          x = @rng.rand * @size
          y = @rng.rand * @size
          next if too_close?(points, x, y, min_dist)
          points << [ x, y ]
        end
        points
      end

      private

      def too_close?(points, x, y, min_dist)
        d2 = min_dist * min_dist
        points.any? { |px, py| (px - x) * (px - x) + (py - y) * (py - y) < d2 }
      end
    end
  end
end
