require "json"

module Harness
  module Quests
    # Renders the authoring system + user prompt for a quest. System is the
    # static preamble (cache-stable). User carries the city context + chosen
    # archetype's slots/steps + the existing local cast.
    #
    # Post-Phase-2: forbidden_names is gone — the LLM no longer picks names
    # (they're assigned mechanically by the committer from the kingdom's
    # naming culture). local_cast is the LLM's reuse-candidate pool.
    module Prompt
      PREAMBLE_PATH = Rails.root.join("lib/harness/prompts/quests.txt")

      def self.render(city:, archetype:, current_game_time:, local_cast: [], rejection_feedback: nil)
        user = "INPUT:\n#{JSON.pretty_generate(input_hash(city, archetype, current_game_time, local_cast))}"

        if rejection_feedback&.any?
          user += "\n" + <<~FEEDBACK

            YOUR PREVIOUS PROPOSAL WAS REJECTED for these reasons:
            #{rejection_feedback.map { |r| "- #{r}" }.join("\n")}

            Regenerate the quest fixing all of these. Output ONLY JSON.
          FEEDBACK
        end

        { system: preamble, user: user }
      end

      def self.input_hash(city, archetype, current_game_time, local_cast)
        {
          "city_name"          => city.name,
          "city_description"   => city.description,
          "biome"              => city.biome,
          "current_game_time"  => current_game_time,
          "archetype_id"       => archetype["id"],
          "prompt_seed"        => archetype["prompt_seed"],
          "slots"              => archetype["slots"],
          "steps"              => archetype["steps"],
          "local_cast"         => local_cast
        }
      end

      def self.preamble
        @preamble ||= ::Harness::Prompts::Preamble.load(PREAMBLE_PATH)
      end

      def self.reload!
        @preamble = nil
      end
    end
  end
end
