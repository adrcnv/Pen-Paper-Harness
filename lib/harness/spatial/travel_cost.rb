module Harness
  module Spatial
    module TravelCost
      BASE_MINUTES = {
        intra_kingdom: (180..480),
        cross_kingdom: (720..2400),
        anchor_link:   (480..1440)
      }.freeze

      TERRAIN_MULTIPLIER = {
        "coast"    => 1.0,
        "plains"   => 0.9,
        "highland" => 1.3,
        "forest"   => 1.2,
        "desert"   => 1.5,
        "marsh"    => 1.6,
        "mountain" => 2.0
      }.freeze
      DEFAULT_MULTIPLIER = 1.0

      def self.for(category:, from_terrain:, to_terrain:, rng: Random.new)
        base = rng.rand(BASE_MINUTES.fetch(category))
        mult = (terrain_multiplier(from_terrain) + terrain_multiplier(to_terrain)) / 2.0
        (base * mult).round
      end

      def self.terrain_multiplier(terrain)
        TERRAIN_MULTIPLIER.fetch(terrain, DEFAULT_MULTIPLIER)
      end
    end
  end
end
