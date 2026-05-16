require "json"

module Harness
  module Combat
    # One LLM call per combat round — renders the round's prose. Input is
    # structured (per-actor result list); output is a single string with
    # bracket lines + 1-2 paragraphs of prose.
    #
    # Falls back to a one-line mechanical summary if the LLM is unavailable
    # (combat keeps moving; you just get terse output).
    module EndOfRoundNarration
      PROMPT_PATH = ::File.expand_path("../prompts/combat_round_narration.txt", __dir__)

      def self.run(round:, actions:, llm:, logger: ::Rails.logger)
        return fallback(round, actions) if llm.nil?

        system = ::File.read(PROMPT_PATH)
        user   = ::JSON.pretty_generate({
          "round"   => round,
          "actions" => actions
        })
        llm.complete(system: system, user: user).to_s.strip
      rescue ::StandardError => e
        logger&.warn { "[Combat::EndOfRoundNarration] failed: #{e.class}: #{e.message}" }
        fallback(round, actions)
      end

      def self.fallback(round, actions)
        lines = actions.map do |a|
          tool = a["tool"] || a[:tool]
          name = a["actor_name"] || a[:actor_name] || "Someone"
          result = a["result"] || a[:result] || {}
          outcome = result["outcome"] || "—"
          "#{name}: #{tool} (#{outcome})"
        end
        "[Round #{round}]\n" + lines.join("\n")
      end
    end
  end
end
