module Harness
  module Worldgen
    # Reconstruct a Map struct from persisted DB rows. The seed isn't stored,
    # so the returned Map has seed: nil — Ascii.render falls back to a blank
    # background (no biome backdrop) in that case.
    #
    # Used by the bin/play /map slash command and by any future map UI that
    # wants to read the persisted world.
    module FromDb
      def self.load
        cities_rows  = ::Location.where.not(x: nil).order(:id).to_a
        kingdom_rows = ::Faction.where(is_kingdom: true).order(:id).to_a

        # Map DB ids to internal indices used by Ascii.
        city_index    = cities_rows.each_with_index.to_h { |loc, i| [ loc.id, i ] }
        kingdom_index = kingdom_rows.each_with_index.to_h { |fac, i| [ fac.id, i ] }

        cities = cities_rows.map do |loc|
          City.new(
            id:          city_index[loc.id],
            x:           loc.x,
            y:           loc.y,
            biome:       loc.biome,
            kingdom_id:  kingdom_index[loc.faction_id],
            name:        loc.name,
            description: loc.description
          )
        end

        kingdoms = kingdom_rows.map do |fac|
          # Find the anchor — the first city in this kingdom is a reasonable
          # stand-in. We don't persist anchor identity separately.
          first_city = cities.find { |c| c.kingdom_id == kingdom_index[fac.id] }
          Kingdom.new(
            id:             kingdom_index[fac.id],
            anchor_city_id: first_city&.id,
            name:           fac.name,
            description:    fac.properties.is_a?(Hash) ? fac.properties["description"] : nil
          )
        end

        size = cities.empty? ? 1 : (cities.map { |c| [ c.x, c.y ].max }.max).ceil + 5

        Map.new(seed: nil, size: size, cities: cities, kingdoms: kingdoms)
      end
    end
  end
end
