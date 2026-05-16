module Harness
  module Quests
    # Deterministic Ruby pick of an archetype for a given city. Filters the
    # library by `city.properties.tags`, then weighted-samples. Returns
    # `{archetype:, claimed_slots:}` where claimed_slots is the per-slot set
    # of character ids already used by other active quests at this city
    # (so the authoring pass can avoid double-allocation).
    #
    # No LLM call. No side effects. Used by Quest::Generator.
    module ArchetypePicker
      class NoArchetypeError < StandardError; end

      class << self
        def pick(city:, rng: Random.new)
          tags = Array(city.properties && city.properties["tags"])
          archetypes = ::Harness::Quests::Library.for_city_tags(tags)
          # Exclude archetypes that already have an unfinished instance in
          # this city — prevents stacking 3 missing_couriers in one port.
          existing_ids = ::Quest.where(city_location_id: city.id, state: %w[offered active]).pluck(:archetype_id).to_set
          filtered = archetypes.reject { |a| existing_ids.include?(a["id"]) }
          chosen = ::Harness::Quests::Library.weighted_pick(filtered.any? ? filtered : archetypes, rng: rng)
          raise NoArchetypeError, "no quest archetype available for city ##{city.id} (tags=#{tags.inspect})" unless chosen
          chosen
        end
      end
    end
  end
end
