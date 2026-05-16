require "json"

module Harness
  module Combat
    # When start_combat fires, every real-character (not extras) present in
    # the scene who is NOT explicitly named on a side gets ONE small-model
    # deliberation call: do they flee, watch, join player, or join enemy?
    # Bias is hard-coded into the prompt toward flee/watch — most ordinary
    # people don't pick a side in someone else's fight.
    #
    # Returns one of:
    #   { decision: "flee" | "watch" | "join_player_side" | "join_enemy_side",
    #     reason:   "<one-line>" }
    #
    # Falls back to {decision: "flee", reason: "fled in the chaos"} if the LLM
    # is unavailable or output is malformed (cheap default; people scattering
    # is the safer no-op than freezing into watchers).
    module BystanderDeliberation
      VALID_DECISIONS = %w[flee watch join_player_side join_enemy_side].freeze
      DEFAULT_FALLBACK = { "decision" => "flee", "reason" => "fled in the chaos" }.freeze

      PROMPT_PATH = ::File.expand_path("../prompts/combat_bystander_deliberation.txt", __dir__)

      def self.run(character:, sides:, initiator:, inciting_beat:, llm:, logger: ::Rails.logger)
        return DEFAULT_FALLBACK.dup if llm.nil?

        system = ::File.read(PROMPT_PATH)
        user   = build_user_payload(character, sides, initiator, inciting_beat)

        raw = llm.complete(system: system, user: user)
        parse(raw, logger)
      rescue StandardError => e
        logger&.warn { "[Combat::BystanderDeliberation] #{character.name} (id=#{character.id}) failed: #{e.class}: #{e.message}" }
        DEFAULT_FALLBACK.dup
      end

      def self.build_user_payload(character, sides, initiator, inciting_beat)
        props = character.properties.is_a?(::Hash) ? character.properties : {}
        ::JSON.pretty_generate({
          "character" => {
            "id"           => character.id,
            "name"         => character.name,
            "subrole"      => character.subrole,
            "personality"  => props["personality"],
            "faction_id"   => props["faction_id"],
            "follower"     => props["following_player"] == true
          },
          "initiator" => initiator,
          "sides"     => sides.map { |s| { "name" => s["name"], "members" => s["members"] } },
          "inciting_beat" => inciting_beat
        })
      end

      def self.parse(raw, logger)
        text = raw.is_a?(::String) ? raw.strip : raw.to_s.strip
        text = text.sub(/\A```(?:json)?\s*/i, "").sub(/```\s*\z/, "").strip
        parsed = ::JSON.parse(text)
        decision = parsed["decision"].to_s.strip
        unless VALID_DECISIONS.include?(decision)
          logger&.warn { "[Combat::BystanderDeliberation] invalid decision #{decision.inspect}; falling back to flee" }
          return DEFAULT_FALLBACK.dup
        end
        reason = parsed["reason"].to_s.strip
        reason = "no reason given" if reason.empty?
        { "decision" => decision, "reason" => reason }
      rescue ::JSON::ParserError => e
        logger&.warn { "[Combat::BystanderDeliberation] JSON parse failed: #{e.message}; falling back to flee" }
        DEFAULT_FALLBACK.dup
      end
    end
  end
end
