module Harness
  module Worldgen
    # Biome assignment from a Noise sample. v1 has two: lowland and highland.
    # Threshold-based, no rivers / moisture / sea — those are additive later
    # (new noise channels, new enum values, no schema breakage).
    module Biome
      LOWLAND  = "lowland".freeze
      HIGHLAND = "highland".freeze

      ALL = [ LOWLAND, HIGHLAND ].freeze

      THRESHOLD = 0.55

      def self.at(noise:, x:, y:)
        sample = noise.at(x, y)
        sample >= THRESHOLD ? HIGHLAND : LOWLAND
      end

      # Travel-cost multiplier per biome. Highland is rougher to traverse;
      # Tools::Travel and Tools::QueryLocationByName apply the average over
      # the endpoints of a journey segment.
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
