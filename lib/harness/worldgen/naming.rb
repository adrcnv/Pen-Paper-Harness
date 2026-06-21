module Harness
  module Worldgen
    # Naming and description pass. NAMES are mechanical (per-culture morphology
    # pools via Harness::Naming — same regime as people, globally unique across
    # locations AND factions). The LLM is kept ONLY for DESCRIPTIONS (sensory
    # texture); any name it emits is discarded, exactly as the character
    # hydrators drop LLM-supplied names. One LLM call per kingdom (batched over
    # its members for tonal coherence). Grunt tier.
    #
    # Uses `llm.complete(system:, user:)` directly — system head is identical
    # across every per-kingdom call within a worldgen pass, so the
    # AnthropicAdapter's cache_control breakpoint hits on calls 2..N.
    module Naming
      MAX_RETRIES = 2

      def self.name!(map:, llm:, logger: Rails.logger)
        taken = ::Harness::Naming.taken_set
        map.kingdoms.each do |kingdom|
          members = map.cities.select { |c| c.kingdom_id == kingdom.id }
          next if members.empty?

          # 1. Mechanical naming FIRST: roll a culture for the kingdom, then
          #    draw globally-unique names for it and every member city.
          culture = ::Harness::Naming::Library.weighted_pick
          kingdom.culture_id = culture["id"]
          kingdom.name = ::Harness::Naming.unique_kingdom_name_for(culture: culture, taken: taken)
          members.each do |c|
            c.name = ::Harness::Naming.unique_place_for(culture: culture, taken: taken)
          end

          # 2. LLM pass for DESCRIPTIONS only (names from step 1 are kept).
          system, user = Prompt.build(kingdom: kingdom, members: members)
          hydrated = call_with_retry(llm: llm, system: system, user: user,
                                     member_ids: members.map(&:id),
                                     kingdom_id: kingdom.id, logger: logger)
          apply_descriptions!(map: map, kingdom: kingdom, hydrated: hydrated)
        end
        map
      end

      def self.call_with_retry(llm:, system:, user:, member_ids:, kingdom_id:, logger:)
        attempt = 0
        last_error = nil
        while attempt < MAX_RETRIES
          attempt += 1
          logger&.debug { "[Worldgen::Naming] kingdom=#{kingdom_id} attempt=#{attempt}" }
          raw = llm.complete(system: system, user: user)
          begin
            return Hydrator.hydrate(llm_output: raw, member_ids: member_ids)
          rescue Hydrator::InvalidOutput => e
            last_error = e
            logger&.warn { "[Worldgen::Naming] kingdom=#{kingdom_id} hydrator failed (attempt #{attempt}/#{MAX_RETRIES}): #{e.message.lines.first.strip}" }
          end
        end
        raise last_error
      end

      # Apply ONLY descriptions from the LLM output; names are already set
      # mechanically in name!. Any name the model emitted is ignored.
      def self.apply_descriptions!(map:, kingdom:, hydrated:)
        kingdom.description = hydrated[:kingdom][:description]
        hydrated[:cities].each do |city_id, attrs|
          city = map.cities.find { |c| c.id == city_id }
          next unless city
          city.description = attrs[:description]
        end
      end
    end
  end
end
