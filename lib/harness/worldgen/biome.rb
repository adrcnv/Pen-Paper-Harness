module Harness
  module Worldgen
    # The COARSE two-bucket view of terrain: lowland vs highland. This is NOT a
    # separate classifier anymore — it's a projection OF Worldgen::Terrain, so
    # the two can never disagree. The fine terrain taxonomy (10 land types) is
    # the single source of truth; `coarse` collapses it to the binary that the
    # cheaper consumers want: travel-cost fallback, quest tags/debt, and the
    # lowland/highland context fed to genesis / catch-up / quest / naming
    # prompts (and the optional scenario `requires: {biome: ...}` gate).
    #
    # (Historically Biome.at sampled an INDEPENDENT noise channel unrelated to
    # elevation — that was the inconsistency this collapse removes.)
    module Biome
      LOWLAND  = "lowland".freeze
      HIGHLAND = "highland".freeze

      ALL = [ LOWLAND, HIGHLAND ].freeze

      # Terrain types that read as rough/elevated country. Everything else
      # (coastal, river_valley, grassland, floodplain, marsh, forest_lowland)
      # collapses to lowland.
      HIGHLAND_TERRAINS = %i[mountain crags forest_upland moor].freeze

      # Collapse a fine terrain (symbol or string) to lowland/highland.
      def self.coarse(terrain)
        HIGHLAND_TERRAINS.include?(terrain.to_sym) ? HIGHLAND : LOWLAND
      end

      # Travel-cost multiplier per biome. Highland is rougher to traverse.
      # Used only as the coarse fallback when fine terrain isn't sampleable
      # (pre-geography saves); the live path uses Terrain.cost_multiplier.
      def self.cost_multiplier(biome)
        case biome
        when LOWLAND  then 1.0
        when HIGHLAND then 1.8
        else 1.0
        end
      end
    end
  end
end
