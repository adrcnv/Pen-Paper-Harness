require "json"

module Harness
  module Description
    class Prompt
      PREAMBLE_PATH = Rails.root.join("lib/harness/prompts/description_materializer.txt")

      # Renders the description materializer prompt. Stats + level are
      # required (this step runs AFTER stats materialization and conditions
      # on them). prose_context and scenario_seed mirror the stats
      # materializer — same shape, same routing (everything dynamic into
      # user, preamble stays system-stable for caching).
      def self.render(character:, prose_context: nil, scenario_seed: nil)
        user = "INPUT:\n#{JSON.pretty_generate(input_hash(character, prose_context))}"

        if scenario_seed.is_a?(String) && !scenario_seed.strip.empty?
          user += "\n\n#{scenario_seed.strip}\n"
        end

        { system: preamble, user: user }
      end

      def self.input_hash(character, prose_context)
        props = character.properties || {}
        h = {
          "name"       => character.name,
          "subrole"    => character.subrole,
          "gender"     => props["gender"],
          "level"      => character.level,
          "stats"      => ::Character::STATS.each_with_object({}) { |s, acc| acc[s] = character.read_attribute(s) },
          "properties" => props
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
