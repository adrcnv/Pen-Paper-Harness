require "json"

module Harness
  module CatchUp
    module Prompt
      PREAMBLE_PATH = Rails.root.join("lib/harness/prompts/catch_up.txt")

      def self.render(location_name:, description:, parent_name:, biome:, current_game_time:, floor_game_time:, setting: nil, recent_actors: [], recent_events: [], scenario_seed: nil, rejection_feedback: nil)
        user = "INPUT:\n#{JSON.pretty_generate(input_hash(location_name, description, parent_name, biome, setting, current_game_time, floor_game_time, recent_actors, recent_events))}"

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

      def self.input_hash(location_name, description, parent_name, biome, setting, current_game_time, floor_game_time, recent_actors, recent_events)
        {
          "location_name"     => location_name,
          "description"       => description,
          "parent_name"       => parent_name,
          "biome"             => biome,
          "setting"           => setting,
          "current_game_time" => current_game_time,
          "floor_game_time"   => floor_game_time,
          "gap"               => current_game_time - floor_game_time,
          "recent_actors"     => recent_actors,
          "recent_events"     => recent_events
        }.compact
      end

      def self.preamble
        @preamble ||= Harness::Prompts::Preamble.load(PREAMBLE_PATH)
      end
    end
  end
end
