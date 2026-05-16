module Harness
  module Worldgen
    # Naming and description pass. Mutates the map's cities and kingdoms
    # in place with LLM-generated names + descriptions. One LLM call per
    # kingdom (batched over its members for tonal coherence). Grunt tier.
    #
    # Uses `llm.complete(system:, user:)` directly — system head is identical
    # across every per-kingdom call within a worldgen pass, so the
    # AnthropicAdapter's cache_control breakpoint hits on calls 2..N.
    module Naming
      MAX_RETRIES = 2

      def self.name!(map:, llm:, logger: Rails.logger)
        map.kingdoms.each do |kingdom|
          members = map.cities.select { |c| c.kingdom_id == kingdom.id }
          next if members.empty?

          system, user = Prompt.build(kingdom: kingdom, members: members)
          hydrated = call_with_retry(llm: llm, system: system, user: user,
                                     member_ids: members.map(&:id),
                                     kingdom_id: kingdom.id, logger: logger)
          apply!(map: map, kingdom: kingdom, hydrated: hydrated)
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

      def self.apply!(map:, kingdom:, hydrated:)
        kingdom.name        = hydrated[:kingdom][:name]
        kingdom.description = hydrated[:kingdom][:description]
        hydrated[:cities].each do |city_id, attrs|
          city = map.cities.find { |c| c.id == city_id }
          next unless city
          city.name        = attrs[:name]
          city.description = attrs[:description]
        end
      end
    end
  end
end
