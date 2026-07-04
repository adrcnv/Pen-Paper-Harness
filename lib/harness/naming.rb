require "set"

module Harness
  # Mechanical name generator. Replaces the LLM as the source of new
  # character names for background spawn paths (Genesis /
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

      # ── Place naming ──────────────────────────────────────────────────
      # Locations and kingdoms are named MECHANICALLY, the same principle as
      # people: per-culture morphology pools, NOT the LLM (which produced the
      # "two Oakhavens plus an Oakhaven Reach" trope-pit). place_for compounds
      # a prefix with a suffix ("Oak"+"haven" → Oakhaven) or, ~WORD_FORM_CHANCE
      # of the time, a space-separated word ("Oak Ridge"). kingdom_name_for
      # adds a realm word ("Oakhaven March", "The Grey Weald"). The unique_*
      # variants reject collisions against BOTH Locations and Factions (so a
      # city can't share a name with a kingdom) plus an optional in-memory
      # `taken` set (worldgen names rows that aren't persisted yet, so the DB
      # check alone wouldn't catch a sibling named earlier in the same pass).
      WORD_FORM_CHANCE = 0.28

      def place_for(culture:, rng: Random.new)
        pre   = sample(place_prefix_pool(culture), rng)
        words = Array(culture["place_word"])
        if words.any? && rng.rand < WORD_FORM_CHANCE
          "#{pre} #{sample(words, rng)}"
        else
          "#{pre}#{sample(place_suffix_pool(culture), rng)}"
        end
      end

      def kingdom_name_for(culture:, rng: Random.new)
        ksuf = sample(kingdom_suffix_pool(culture), rng)
        if rng.rand < 0.5
          "#{compound(culture, rng)} #{ksuf}"                      # "Oakhaven March"
        else
          "The #{sample(place_prefix_pool(culture), rng)} #{ksuf}" # "The Grey Weald"
        end
      end

      def unique_place_for(culture:, rng: Random.new, taken: nil, attempts: 40)
        resolve_unique(taken: taken, attempts: attempts) { place_for(culture: culture, rng: rng) } ||
          disambiguated(taken: taken) { place_for(culture: culture, rng: rng) }
      end

      def unique_kingdom_name_for(culture:, rng: Random.new, taken: nil, attempts: 40)
        resolve_unique(taken: taken, attempts: attempts) { kingdom_name_for(culture: culture, rng: rng) } ||
          disambiguated(taken: taken) { kingdom_name_for(culture: culture, rng: rng) }
      end

      # Downcased name set of every existing Location + Faction — seed for a
      # worldgen pass's `taken` set so incremental generation onto a populated
      # save never reuses a name, and siblings named earlier in the same pass
      # (not yet persisted) are still avoided.
      def taken_set
        set = ::Set.new
        ::Location.pluck(:name).each { |n| set << n.to_s.downcase }
        ::Faction.pluck(:name).each  { |n| set << n.to_s.downcase }
        set
      end

      private

      DEFAULT_PLACE_PREFIX   = %w[Oak Ash Stone Grey Cold Fen Mire High Black Long].freeze
      DEFAULT_PLACE_SUFFIX   = %w[haven hold ford ton mere field gate dale].freeze
      DEFAULT_KINGDOM_SUFFIX = %w[March Reach Realm Dominion].freeze

      def place_prefix_pool(culture)   = Array(culture["place_prefix"]).reject(&:empty?).presence || DEFAULT_PLACE_PREFIX
      def place_suffix_pool(culture)   = Array(culture["place_suffix"]).reject(&:empty?).presence || DEFAULT_PLACE_SUFFIX
      def kingdom_suffix_pool(culture) = Array(culture["kingdom_suffix"]).reject(&:empty?).presence || DEFAULT_KINGDOM_SUFFIX

      def compound(culture, rng)
        "#{sample(place_prefix_pool(culture), rng)}#{sample(place_suffix_pool(culture), rng)}"
      end

      # Try the generator up to `attempts` times for a free name; mark and
      # return the first, or nil if all attempts collided.
      def resolve_unique(taken:, attempts:)
        attempts.times do
          name = yield
          next if name_taken?(name, taken)
          mark!(name, taken)
          return name
        end
        nil
      end

      # Last-resort disambiguation: prefix a direction, then (worst case) a
      # Roman numeral — guaranteed to terminate.
      def disambiguated(taken:)
        base = yield
        %w[North South East West Upper Lower Old New Far Near].each do |dir|
          cand = "#{dir} #{base}"
          next if name_taken?(cand, taken)
          mark!(cand, taken)
          return cand
        end
        n = 2
        n += 1 while name_taken?("#{base} #{roman(n)}", taken)
        cand = "#{base} #{roman(n)}"
        mark!(cand, taken)
        cand
      end

      def name_taken?(name, taken)
        key = name.to_s.downcase
        return true if taken&.include?(key)
        ::Location.exists?(name: name) || ::Faction.exists?(name: name)
      end

      def mark!(name, taken)
        taken << name.to_s.downcase if taken
      end

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
