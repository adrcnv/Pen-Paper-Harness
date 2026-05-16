module Harness
  module Description
    # Generates personality + physical appearance for a character that has
    # already been given stats and a level. Runs AFTER Stats::Materializer
    # in Character::Hatchery, so stats are available to condition on (a
    # STR-17 character looks broad-shouldered, an INT-18 scholar has sharp
    # eyes, a level-12 retired-archmage barkeep has one detail wrong for
    # the cover).
    #
    # Writes both fields into character.properties:
    #   - properties.personality (existing convention; multiple readers
    #     including InternalState, belief, character_catch_up)
    #   - properties.appearance  (new structural key for physical/visible
    #     traits; observable, not interior state)
    #
    # Player rows are no-ops (player description is the player's concern,
    # not LLM territory).
    class Materializer
      attr_reader :logger

      def initialize(llm_client:, logger: Rails.logger, max_retries: 2)
        @llm         = llm_client
        @logger      = logger
        @max_retries = max_retries
      end

      def materialize!(character, prose_context: nil, scenario_seed: nil)
        return character if character.is_a?(::Player)

        ::Harness::CostTracker.in_subsystem(:description_materializer) do
          logger.info { "[Description::Materializer] generating description for character=#{character.name} subrole=#{character.subrole.inspect} level=#{character.level} scenario=#{scenario_seed ? 'present' : 'none'}" }
          fields = call_with_retries(character, prose_context: prose_context, scenario_seed: scenario_seed)
          merged = (character.properties || {}).merge(
            "personality" => fields[:personality],
            "appearance"  => fields[:appearance]
          )
          character.update!(properties: merged)
          character.reload
        end
      end

      private

      def call_with_retries(character, prose_context:, scenario_seed:)
        attempts     = 0
        prompt       = Prompt.render(character: character, prose_context: prose_context, scenario_seed: scenario_seed)
        current_user = prompt[:user]

        loop do
          attempts += 1
          logger.debug { "[Description::Materializer] attempt #{attempts}" }

          raw = @llm.complete(system: prompt[:system], user: current_user)
          logger.debug { "[Description::Materializer] raw (attempt #{attempts}, #{raw.size} bytes): #{raw}" }

          begin
            return Hydrator.hydrate(llm_output: raw)
          rescue Hydrator::InvalidOutput => e
            logger.warn { "[Description::Materializer] validation failed (attempt #{attempts}/#{@max_retries + 1}): #{e.errors.join('; ')}" }
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
