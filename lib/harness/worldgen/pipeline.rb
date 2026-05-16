module Harness
  module Worldgen
    # Top-level orchestrator: math → naming → persistence. One call, one
    # generated world. Returns the populated Map struct AND the id-mapping
    # from Persister so callers can reach DB rows.
    #
    # All three stages are kept separate so they can be exercised
    # independently in tests (math without LLM, naming without DB, etc.).
    module Pipeline
      def self.run!(seed:, llm:, size: Generator::DEFAULT_SIZE,
                    city_count: Generator::DEFAULT_CITY_COUNT,
                    kingdom_count: Generator::DEFAULT_KINGDOM_COUNT,
                    logger: Rails.logger)
        logger&.info { "[Worldgen::Pipeline] seed=#{seed} size=#{size} cities=#{city_count} kingdoms=#{kingdom_count}" }

        map = Generator.generate(
          seed:          seed,
          size:          size,
          city_count:    city_count,
          kingdom_count: kingdom_count
        )
        logger&.info { "[Worldgen::Pipeline] generated: #{map.cities.size} cities, #{map.kingdoms.size} kingdoms" }

        Naming.name!(map: map, llm: llm, logger: logger)
        logger&.info { "[Worldgen::Pipeline] named: #{map.kingdoms.map(&:name).inspect}" }

        ids = Persister.persist!(map: map)
        logger&.info { "[Worldgen::Pipeline] persisted: kingdom_ids=#{ids[:kingdoms].values}, city_ids=#{ids[:cities].values.size} rows" }

        { map: map, ids: ids }
      end
    end
  end
end
