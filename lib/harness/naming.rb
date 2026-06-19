module Harness
  # Mechanical name generator. Replaces the LLM as the source of new
  # character names for background spawn paths (Quest gen / Genesis /
  # Scene::Materializer when they sweep through Phase 3). The reasoning
  # loop's propose_character path STAYS LLM-named because the player
  # picks names in conversation; this primitive is for engine-driven
  # spawns only.
  #
  # Algorithm:
  #   1. Walk parent chain from `location` to find a top-level row with a
  #      `faction_id` pointing at an `is_kingdom: true` faction.
  #   2. Read `kingdom.properties.culture_id`.
  #   3. Look up culture in Library; if not found, fall back to default.
  #   4. Roll a gender, sample a `given` from that gender's pool, and a
  #      `family` from the shared family pool. The drawn name therefore
  #      implies a gender (recoverable via .gender_for).
  #
  # Idempotency: every call is independent. The same location can produce
  # different names on different calls (that's the point). Use rng for
  # deterministic tests.
  #
  # Bulk-assign cultures to existing kingdoms after a worldgen migration
  # with `Harness::Naming.assign_to_kingdoms!` — idempotent, only writes
  # `culture_id` when missing.
  module Naming
    class << self
      def for(location:, rng: Random.new)
        culture = culture_for(location) || Library.default
        given   = sample(given_pool(culture, rng), rng)
        family  = culture["family"].any? ? sample(culture["family"], rng) : nil
        [ given, family ].compact.reject(&:empty?).join(" ")
      end

      # Which gender a given name belongs to, by membership in the culture
      # pools. Checks the first token (the given name) across ALL cultures —
      # a name's gender is a property of the name, not of the kingdom that
      # drew it. Returns "male" / "female", or nil for a name in no pool
      # (an LLM-invented name from propose_character). The pools are disjoint
      # so the answer is unambiguous. Hatchery uses this to ground
      # properties.gender at spawn so every downstream reader agrees.
      def gender_for(name)
        first = name.to_s.strip.split(/\s+/).first
        return nil if first.nil? || first.empty?
        Library.all.each do |c|
          return "male"   if Array(c["given_male"]).include?(first)
          return "female" if Array(c["given_female"]).include?(first)
        end
        nil
      end

      # Same as `.for` but avoids name collisions with existing Character
      # rows. With 30 given × 30 family per culture (~900 combinations) and
      # a typical save under 100 characters, collisions are rare. After
      # `attempts` retries we fall back to appending a Roman-numeral suffix
      # (Halric Morvanir II) — fine for the rare case, never blocks a spawn.
      def unique_for(location:, rng: Random.new, attempts: 5)
        attempts.times do
          name = self.for(location: location, rng: rng)
          return name unless ::Character.exists?(name: name)
        end
        # Fallback: pick once more, append a discriminator until free.
        base   = self.for(location: location, rng: rng)
        suffix = 2
        while ::Character.exists?(name: "#{base} #{roman(suffix)}")
          suffix += 1
        end
        "#{base} #{roman(suffix)}"
      end

      # Resolve a location to its kingdom's culture hash. Returns nil when:
      #   - no ancestor has a faction
      #   - the faction isn't a kingdom (is_kingdom: false)
      #   - the kingdom has no culture_id set (legacy saves pre-naming)
      #   - the culture_id doesn't match a loaded culture (renamed/deleted YAML)
      def culture_for(location)
        kingdom = kingdom_for(location)
        return nil unless kingdom
        culture_id = (kingdom.properties || {})["culture_id"]
        return nil unless culture_id
        Library.find(culture_id)
      end

      def kingdom_for(location)
        current = location
        while current
          if current.faction_id
            faction = current.faction
            return faction if faction&.is_kingdom
          end
          break if current.parent_id.nil?
          current = current.parent
        end
        nil
      end

      # Bulk hook for older saves: walk every is_kingdom faction, assign a
      # culture if none is set. Pure idempotent — re-running is safe and
      # cheap (no LLM calls). Useful for migrating in-progress games to the
      # naming layer after the YAMLs ship.
      def assign_to_kingdoms!(rng: Random.new)
        ::Faction.where(is_kingdom: true).find_each do |k|
          props = k.properties || {}
          next if props["culture_id"]
          culture = Library.weighted_pick(rng: rng)
          props["culture_id"] = culture["id"]
          k.update!(properties: props)
        end
      end

      private

      # Roll a gender, return the matching given-name pool. Falls back to the
      # combined/legacy `given` pool when a culture lacks the gendered pools
      # (test stubs, hand-built culture hashes). The gender roll consumes one
      # rng draw before the name sample, which is fine — callers that need
      # determinism seed their own rng.
      def given_pool(culture, rng)
        male   = Array(culture["given_male"])
        female = Array(culture["given_female"])
        if male.any? && female.any?
          rng.rand < 0.5 ? male : female
        else
          Array(culture["given"])
        end
      end

      def sample(pool, rng)
        pool[rng.rand(pool.size)]
      end

      ROMAN_NUMERALS = %w[I II III IV V VI VII VIII IX X XI XII XIII XIV XV].freeze
      def roman(n)
        ROMAN_NUMERALS[n - 1] || n.to_s
      end
    end
  end
end
