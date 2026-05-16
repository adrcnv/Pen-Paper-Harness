module Harness
  module Worldgen
    # Kingdom assignment via nearest-anchor classification. Not a full Voronoi
    # diagram — we don't draw cell boundaries, just label each point with the
    # nearest anchor's index. Anchors are chosen from the city set itself.
    module Voronoi
      # Pick `count` anchors from the city list, deterministically given the
      # seed. v1: random selection (good enough for 3-4 anchors out of 15).
      # When city count is < anchor count, return all cities as anchors.
      def self.pick_anchors(cities:, count:, seed:)
        return (0...cities.size).to_a if cities.size <= count
        rng = Random.new(seed.to_i & 0xFFFFFFFF)
        (0...cities.size).to_a.shuffle(random: rng).first(count).sort
      end

      # Classify every city by nearest anchor. Returns an array of kingdom_ids
      # parallel to cities (kingdom_id is the index into anchor_indices).
      def self.classify(cities:, anchor_indices:)
        anchors = anchor_indices.map { |i| cities[i] }
        cities.map do |c|
          anchors.each_with_index.min_by do |a, _i|
            (a[0] - c[0]) ** 2 + (a[1] - c[1]) ** 2
          end.last
        end
      end
    end
  end
end
