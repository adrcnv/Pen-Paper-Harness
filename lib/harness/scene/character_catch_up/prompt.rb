require "json"

module Harness
  module Scene
    module CharacterCatchUp
      module Prompt
        PREAMBLE_PATH = Rails.root.join("lib/harness/prompts/character_catch_up.txt")

        def self.render(current_game_time:, lookback_window:, characters:, rejection_feedback: nil)
          user = "INPUT:\n#{JSON.pretty_generate(input_hash(current_game_time, lookback_window, characters))}"

          if rejection_feedback&.any?
            user += "\n" + <<~FEEDBACK

              YOUR PREVIOUS PROPOSAL WAS REJECTED for these reasons:
              #{rejection_feedback.map { |r| "- #{r}" }.join("\n")}

              Regenerate fixing all of these. Output ONLY JSON.
            FEEDBACK
          end

          { system: preamble, user: user }
        end

        def self.input_hash(current_game_time, lookback_window, characters)
          {
            "current_game_time" => current_game_time,
            "lookback_window"   => lookback_window,
            "characters"        => characters
          }
        end

        def self.preamble
          @preamble ||= Harness::Prompts::Preamble.load(PREAMBLE_PATH)
        end
      end
    end
  end
end
