module Harness
  module Worldgen
    # Map → DB rows. Two-phase write inside one transaction:
    #   1. Insert Faction rows (one per kingdom, is_kingdom: true) → collect ids
    #   2. Insert Location rows (one per city, top-level, faction_id pointing at kingdom)
    #
    # Persists names/descriptions if Naming has run; nil otherwise (which is
    # fine for testing the persistence layer in isolation).
    #
    # Returns a hash mapping internal Map ids to DB ids:
    #   { kingdoms: { 0 => 12, 1 => 13, ... }, cities: { 0 => 45, 1 => 46, ... } }
    module Persister
      def self.persist!(map:)
        ActiveRecord::Base.transaction do
          kingdom_id_map = persist_kingdoms(map)
          city_id_map    = persist_cities(map, kingdom_id_map)
          persist_world(map)

          { kingdoms: kingdom_id_map, cities: city_id_map }
        end
      end

      # Singleton world metadata (seed + cached rivers) so geography survives a
      # restart and runtime can sample terrain at any point. No-op for hand-built
      # maps without a geography (persistence-layer tests).
      def self.persist_world(map)
        return unless map.geography
        ::World.record!(map.geography)
      end

      def self.persist_kingdoms(map)
        out = {}
        rng = Random.new
        map.kingdoms.each do |k|
          # Prefer the culture the naming pass rolled (so the persisted
          # culture_id matches the one the kingdom's mechanical names were
          # drawn from). Fall back to a fresh weighted pick only for maps
          # persisted without a naming pass (persistence-layer tests).
          culture_id = k.culture_id || ::Harness::Naming::Library.weighted_pick(rng: rng)["id"]
          props      = k.description ? { "description" => k.description } : {}
          props["culture_id"] = culture_id
          row = ::Faction.create!(
            name:       k.name || "Kingdom #{k.id}",
            subrole:    "kingdom",
            is_kingdom: true,
            properties: props
          )
          out[k.id] = row.id
        end
        out
      end

      def self.persist_cities(map, kingdom_id_map)
        out = {}
        rng = Random.new
        map.cities.each do |c|
          row = ::Location.create!(
            name:        c.name || "City #{c.id}",
            description: c.description,
            parent:      nil,
            x:           c.x,
            y:           c.y,
            biome:       c.biome,
            faction_id:  kingdom_id_map[c.kingdom_id],
            properties:  city_properties(c, rng: rng)
          )
          out[c.id] = row.id
        end
        out
      end

      # Properties seeded at worldgen for downstream systems:
      #   tags — descriptive city tags (biome-derived; capital/political tags
      #          TBD). No consumer today (the quest system that read them was
      #          killed); kept as cheap descriptive metadata.
      def self.city_properties(c, rng: Random.new)
        tags = case c.biome
        when ::Harness::Worldgen::Biome::LOWLAND  then %w[lowland trade_hub mercantile]
        when ::Harness::Worldgen::Biome::HIGHLAND then %w[highland frontier]
        else []
        end
        props = {
          "tags" => tags
        }
        # Rich geography facts (additive; biome stays the legacy coarse fact).
        props["terrain"]   = c.terrain   unless c.terrain.nil?
        props["coastal"]   = c.coastal   unless c.coastal.nil?
        props["riverside"] = c.riverside unless c.riverside.nil?

        # Mechanical economic identity (economic_basis / size / wealth). Rolled
        # onto the struct by Worldgen::Profiler BEFORE naming (so the description
        # pass sees the real size); read it back here. Fallback roll covers any
        # caller that persists a map without the profiling step (older tests).
        # See Harness::Settlement::Profile.
        props.merge!(
          if c.size
            { "economic_basis" => c.economic_basis, "size" => c.size, "wealth" => c.wealth }
          else
            ::Harness::Settlement::Profile.roll(
              terrain:   c.terrain,
              coastal:   c.coastal,
              riverside: c.riverside,
              rng:       rng
            )
          end
        )
        props
      end

    end
  end
end
