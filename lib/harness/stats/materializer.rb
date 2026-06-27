module Harness
  module Stats
    # Generates a level + six ability scores for an NPC, conditioned on
    # subrole, properties, optional prose context (event narratives, the
    # materializer prompt that spawned them),
    # and an optional scenario seed (the outlier-injection mechanism for
    # character creation; see lib/harness/scenarios/tables/character_creation.yml).
    #
    # Two invocation modes:
    #   - eager (the default, called via Character::Hatchery at creation):
    #     run unconditionally with full context; the row's stats reflect
    #     identity + tier from birth.
    #   - lazy fallback (materialize_if_needed on first resolve): kept as a
    #     safety net for any character that slipped past the Hatchery seam.
    #     Runs only when stats are missing.
    #
    # Player rows are never materialized — player stats are hand-authored at
    # session start; the materializer treats Player as a no-op.
    class Materializer
      attr_reader :logger

      def initialize(llm_client:, logger: Rails.logger, max_retries: 2)
        @llm         = llm_client
        @logger      = logger
        @max_retries = max_retries
      end

      # Eager path: always runs (regardless of current stats), used by the
      # Hatchery at creation time. Conditions on optional prose context +
      # scenario seed so freshly-spawned characters get stats grounded in
      # whatever just established them.
      def materialize!(character, prose_context: nil, scenario_seed: nil)
        return character if character.is_a?(::Player)

        ::Harness::CostTracker.in_subsystem(:stats_materializer) do
          logger.info { "[Stats::Materializer] materializing stats for character=#{character.name} subrole=#{character.subrole.inspect} scenario=#{scenario_seed ? 'present' : 'none'}" }
          attrs = call_with_retries(character, prose_context: prose_context, scenario_seed: scenario_seed)
          character.update!(attrs)
          character.reload
        end
      end

      # Lazy fallback: skips when stats are already set. Kept so any
      # character that slipped past the Hatchery (legacy data, an unwrapped
      # creation path) still gets stats on first resolve. No prose context
      # available here — uses bare subrole + properties.
      def materialize_if_needed(character)
        return character if character.is_a?(::Player)
        return character if all_stats_set?(character)

        materialize!(character)
      end

      private

      def all_stats_set?(character)
        ::Character::STATS.all? { |s| !character.read_attribute(s).nil? }
      end

      def call_with_retries(character, prose_context:, scenario_seed:)
        attempts     = 0
        prompt       = Prompt.render(character: character, prose_context: prose_context, scenario_seed: scenario_seed)
        current_user = prompt[:user]

        loop do
          attempts += 1
          logger.debug { "[Stats::Materializer] attempt #{attempts}" }

          raw = @llm.complete(system: prompt[:system], user: current_user)
          logger.debug { "[Stats::Materializer] raw (attempt #{attempts}, #{raw.size} bytes): #{raw}" }

          begin
            return Hydrator.hydrate(llm_output: raw)
          rescue Hydrator::InvalidOutput => e
            logger.warn { "[Stats::Materializer] validation failed (attempt #{attempts}/#{@max_retries + 1}): #{e.errors.join('; ')}" }
            raise if attempts > @max_retries
            current_user = repair_user(prompt[:user], raw, e.errors)
          end
        end
      end

      def repair_user(original, bad, errors)
        <<~REPAIR
          #{original}

          YOUR PREVIOUS OUTPUT WAS REJECTED. Here is what you produced:
          #{bad}

          ERRORS:
          #{errors.map { |e| "- #{e}" }.join("\n")}

          Fix ALL errors and output the corrected JSON. No prose around the object.
        REPAIR
      end
    end
  end
end
