require "json"

module Harness
  module Stats
    class Prompt
      PREAMBLE_PATH = Rails.root.join("lib/harness/prompts/stats_materializer.txt")

      # `prose_context` is freeform text about who this character is — event
      # narratives they participated in, the materializer's reason for spawning
      # them. Routed to user (NOT system) so the cache prefix stays stable
      # across calls.
      #
      # `scenario_seed` is the optional outlier-injection from the
      # character_creation scenarios YAML. When present, gets appended after
      # the INPUT block — same pattern as Genesis::Prompt.
      def self.render(character:, prose_context: nil, scenario_seed: nil)
        user = "INPUT:\n#{JSON.pretty_generate(input_hash(character, prose_context))}"

        if scenario_seed.is_a?(String) && !scenario_seed.strip.empty?
          user += "\n\n#{scenario_seed.strip}\n"
        end

        { system: preamble, user: user }
      end

      def self.input_hash(character, prose_context)
        h = {
          "name"       => character.name,
          "subrole"    => character.subrole,
          "properties" => character.properties || {}
        }
        h["context"] = prose_context if prose_context.is_a?(String) && !prose_context.strip.empty?
        h
      end

      def self.preamble
        @preamble ||= Harness::Prompts::Preamble.load(PREAMBLE_PATH)
      end
    end
  end
end
