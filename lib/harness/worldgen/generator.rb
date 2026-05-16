module Harness
  module Worldgen
    # Pure-math worldgen pipeline (v1 pass 1):
    #   1. Build a noise field from the seed.
    #   2. Sample N city positions via poisson rejection.
    #   3. Classify each by biome (lowland/highland).
    #   4. Pick K kingdom anchors, classify all cities by nearest anchor.
    #
    # Output is a Map struct of City + Kingdom. No DB writes, no LLM
    # bindings. Pass 2 layers naming + descriptions on top. Inter-city
    # connectivity used to be Path edges between cities; the Path model was
    # retired in favor of cursor-based travel (any coords → any coords).
    module Generator
      DEFAULT_SIZE          = 100
      DEFAULT_CITY_COUNT    = 15
      DEFAULT_KINGDOM_COUNT = 4
      DEFAULT_MIN_DIST      = 12.0

      def self.generate(seed:, size: DEFAULT_SIZE, city_count: DEFAULT_CITY_COUNT,
                        kingdom_count: DEFAULT_KINGDOM_COUNT, min_city_dist: DEFAULT_MIN_DIST)
        noise = Noise.new(seed: seed)

        positions = Poisson.new(size: size, seed: seed)
          .sample(count: city_count, min_dist: min_city_dist)

        biomes = positions.map { |x, y| Biome.at(noise: noise, x: x, y: y) }

        anchor_indices = Voronoi.pick_anchors(
          cities: positions,
          count:  kingdom_count,
          seed:   seed
        )
        kingdom_ids = Voronoi.classify(cities: positions, anchor_indices: anchor_indices)

        cities = positions.each_with_index.map do |(x, y), i|
          City.new(id: i, x: x, y: y, biome: biomes[i], kingdom_id: kingdom_ids[i])
        end

        kingdoms = anchor_indices.each_with_index.map do |city_idx, kingdom_id|
          Kingdom.new(id: kingdom_id, anchor_city_id: city_idx)
        end

        Map.new(seed: seed, size: size, cities: cities, kingdoms: kingdoms)
      end
    end
  end
end
