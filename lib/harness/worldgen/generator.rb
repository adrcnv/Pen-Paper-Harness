module Harness
  module Worldgen
    # Pure-math worldgen pipeline (v1 pass 1):
    #   1. Build geography from the seed (elevation / sea / rivers / moisture).
    #   2. Sample candidate city positions via poisson, then keep only those on
    #      habitable land (no sea, no peaks), preferring coast/river/fertile.
    #   3. Record each city's biome (coarse) + terrain/coastal/riverside (rich).
    #   4. Pick K kingdom anchors, classify all cities by nearest anchor.
    #
    # Output is a Map struct of City + Kingdom + the Geography they sit on. No
    # DB writes, no LLM bindings. Pass 2 layers naming + descriptions on top.
    # Inter-city connectivity used to be Path edges between cities; the Path
    # model was retired in favor of cursor-based travel (any coords → any coords).
    module Generator
      DEFAULT_SIZE          = 100
      DEFAULT_CITY_COUNT    = 15
      DEFAULT_KINGDOM_COUNT = 4
      DEFAULT_MIN_DIST      = 12.0

      # How many spaced candidates to over-sample before habitability filtering.
      CANDIDATE_FACTOR      = 4
      # Below this habitability a point is too hostile to seat a city (sea = 0,
      # mountain ≈ 0.05). Coast/floodplain/grassland clear it comfortably.
      MIN_HABITABILITY      = 0.25

      def self.generate(seed:, size: DEFAULT_SIZE, city_count: DEFAULT_CITY_COUNT,
                        kingdom_count: DEFAULT_KINGDOM_COUNT, min_city_dist: DEFAULT_MIN_DIST)
        geo = Geography.generate(seed: seed, size: size)

        positions = place_cities(geo, size, seed, city_count, min_city_dist)

        anchor_indices = Voronoi.pick_anchors(
          cities: positions,
          count:  kingdom_count,
          seed:   seed
        )
        kingdom_ids = Voronoi.classify(cities: positions, anchor_indices: anchor_indices)

        cities = positions.each_with_index.map do |(x, y), i|
          terrain = Terrain.at(geo: geo, x: x, y: y)
          City.new(
            id: i, x: x, y: y,
            terrain:    terrain.to_s,
            biome:      Biome.coarse(terrain),   # coarse projection, single-sourced from terrain
            coastal:    geo.coastal?(x, y),
            riverside:  geo.riverside?(x, y),
            kingdom_id: kingdom_ids[i]
          )
        end

        kingdoms = anchor_indices.each_with_index.map do |city_idx, kingdom_id|
          Kingdom.new(id: kingdom_id, anchor_city_id: city_idx)
        end

        Map.new(seed: seed, size: size, cities: cities, kingdoms: kingdoms, geography: geo)
      end

      # Over-sample spaced candidates, drop the uninhabitable (sea, peaks), and
      # take the most habitable `city_count`. Falls back to the raw candidates
      # if filtering would starve the map (tiny/island seeds). Deterministic:
      # ordering is by habitability then original index, both seed-derived.
      def self.place_cities(geo, size, seed, city_count, min_city_dist)
        candidates = Poisson.new(size: size, seed: seed)
          .sample(count: city_count * CANDIDATE_FACTOR, min_dist: min_city_dist)

        habitable = candidates.each_with_index.select do |(x, y), _i|
          Terrain.habitability(Terrain.at(geo: geo, x: x, y: y)) >= MIN_HABITABILITY
        end

        chosen =
          if habitable.size >= city_count
            habitable
              .sort_by { |(x, y), i| [ -Terrain.habitability(Terrain.at(geo: geo, x: x, y: y)), i ] }
              .first(city_count)
              .sort_by { |_pos, i| i }       # restore spatial/seed order for stable ids
              .map(&:first)
          else
            candidates.first(city_count)     # degenerate seed — take what we have
          end

        chosen
      end
    end
  end
end
