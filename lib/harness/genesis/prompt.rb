require "json"

module Harness
  module Genesis
    module Prompt
      PREAMBLE_PATH = Rails.root.join("lib/harness/prompts/genesis.txt")

      def self.render(location_name:, description:, biome:, anchor_name:, anchor_biome:, current_game_time:, setting: nil, connection: nil, regional_context: [], scenario_seed: nil, rejection_feedback: nil)
        user = "INPUT:\n#{JSON.pretty_generate(input_hash(location_name, description, biome, setting, anchor_name, anchor_biome, current_game_time, connection, regional_context))}"

        if scenario_seed && !scenario_seed.strip.empty?
          user += "\n\n#{scenario_seed.strip}\n"
        end

        if rejection_feedback&.any?
          user += "\n" + <<~FEEDBACK

            YOUR PREVIOUS PROPOSAL WAS REJECTED for these reasons:
            #{rejection_feedback.map { |r| "- #{r}" }.join("\n")}

            Regenerate the events fixing all of these. Output ONLY JSON.
          FEEDBACK
        end

        { system: preamble, user: user }
      end

      def self.input_hash(location_name, description, biome, setting, anchor_name, anchor_biome, current_game_time, connection, regional_context)
        {
          "location_name"     => location_name,
          "description"       => description,
          "biome"              => biome,
          "setting"            => setting,
          "anchor_name"        => anchor_name,
          "anchor_biome"       => anchor_biome,
          "current_game_time"  => current_game_time,
          "connection"         => connection,
          "regional_context"   => regional_context
        }.compact
      end

      def self.preamble
        @preamble ||= Harness::Prompts::Preamble.load(PREAMBLE_PATH)
      end
    end
  end
end
