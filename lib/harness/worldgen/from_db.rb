module Harness
  module Worldgen
    # Reconstruct a Map struct from persisted DB rows. The geography (seed +
    # cached rivers) is restored from the `worlds` row when present, so Ascii can
    # redraw the terrain backdrop + rivers. Worlds generated before that row
    # existed have geography: nil and fall back to a blank background.
    #
    # Used by the bin/play /map slash command and by any future map UI that
    # wants to read the persisted world.
    module FromDb
      def self.load
        cities_rows  = ::Location.where.not(x: nil).order(:id).to_a
        kingdom_rows = ::Faction.where(is_kingdom: true).order(:id).to_a
        world        = ::World.current

        # Map DB ids to internal indices used by Ascii.
        city_index    = cities_rows.each_with_index.to_h { |loc, i| [ loc.id, i ] }
        kingdom_index = kingdom_rows.each_with_index.to_h { |fac, i| [ fac.id, i ] }

        cities = cities_rows.map do |loc|
          props = loc.properties.is_a?(Hash) ? loc.properties : {}
          City.new(
            id:          city_index[loc.id],
            x:           loc.x,
            y:           loc.y,
            biome:          loc.biome,
            terrain:        props["terrain"],
            coastal:        props["coastal"],
            riverside:      props["riverside"],
            economic_basis: props["economic_basis"],
            size:           props["size"],
            wealth:         props["wealth"],
            kingdom_id:     kingdom_index[loc.faction_id],
            name:           loc.name,
            description:    loc.description
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

        geo  = world&.geography
        seed = world&.seed
        size = geo&.size ||
               (cities.empty? ? 1 : (cities.map { |c| [ c.x, c.y ].max }.max).ceil + 5)

        Map.new(seed: seed, size: size, cities: cities, kingdoms: kingdoms, geography: geo)
      end
    end
  end
end
