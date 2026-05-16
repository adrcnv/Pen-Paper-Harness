require "json"

module Harness
  module Combat
    # When the player escapes successfully, combat is over for them but
    # other combatants are still left in the scene with no observer. This
    # module fires ONE LLM call with the remaining combatants and a one-
    # line summary, gets back a structured outcome list, and applies state
    # changes (HP zero on kills, location wipe on flees, items dropped).
    #
    # A propose_event captures the wrap-up prose at the abandoned location.
    # Catch-up at next entry surfaces it naturally ("Bram was killed three
    # days ago when Vek and Rask overran the watchtower").
    #
    # Falls back to "everyone survived" if the LLM is unavailable — players
    # who later return to the scene of an abandoned fight just see no
    # corpses, which is wrong but not catastrophic. With LLM the typical
    # flow surfaces real consequences.
    module PlayerFledResolution
      PROMPT_PATH = ::File.expand_path("../prompts/combat_player_fled.txt", __dir__)

      def self.run(scene:, fight_summary:, llm:, context:, logger: ::Rails.logger)
        state = scene.combat
        remaining = remaining_combatants(state)
        return { "skipped" => true, "reason" => "no remaining combatants" } if remaining.empty?

        outcomes = if llm
          query_llm(remaining, state.round, fight_summary, llm, logger)
        else
          { "summary_prose" => "Without the player there to mark the moment, the fight ends in confusion.", "outcomes" => remaining.map { |c| { "character_id" => c.id, "result" => "survived" } } }
        end

        apply_outcomes!(outcomes, scene, context, logger)
        outcomes
      end

      def self.remaining_combatants(state)
        state.sides.keys.map { |id| ::Character.find_by(id: id) }.compact.reject do |c|
          c.is_a?(::Player) || (c.max_hp.to_i > 0 && c.current_hp.to_i <= 0)
        end
      end

      def self.query_llm(remaining, round, fight_summary, llm, logger)
        system = ::File.read(PROMPT_PATH)
        user   = ::JSON.pretty_generate({
          "round_when_player_fled" => round,
          "fight_summary"          => fight_summary,
          "combatants" => remaining.map { |c| {
            "id"       => c.id,
            "name"     => c.name,
            "side"     => nil, # filled by caller via state if needed
            "hp"       => "#{c.current_hp}/#{c.max_hp}",
            "abilities" => Array(c.abilities).map { |a| a["name"] }
          } }
        })
        raw = llm.complete(system: system, user: user)
        parse(raw, remaining, logger)
      end

      def self.parse(raw, remaining, logger)
        text = raw.to_s.strip.sub(/\A```(?:json)?\s*/i, "").sub(/```\s*\z/, "").strip
        parsed = ::JSON.parse(text)

        unless parsed.is_a?(::Hash) && parsed["outcomes"].is_a?(::Array)
          logger&.warn { "[Combat::PlayerFledResolution] malformed JSON; defaulting to all survived" }
          return { "summary_prose" => "The fight scatters in the player's wake.", "outcomes" => remaining.map { |c| { "character_id" => c.id, "result" => "survived" } } }
        end

        parsed
      rescue ::JSON::ParserError => e
        logger&.warn { "[Combat::PlayerFledResolution] JSON parse failed: #{e.message}" }
        { "summary_prose" => "The fight scatters in the player's wake.", "outcomes" => remaining.map { |c| { "character_id" => c.id, "result" => "survived" } } }
      end

      def self.apply_outcomes!(outcomes, scene, context, logger)
        Array(outcomes["outcomes"]).each do |o|
          char = ::Character.find_by(id: o["character_id"])
          next unless char

          case o["result"]
          when "killed"
            char.update!(current_hp: 0)
            ::Harness::Items::Loot.drop_to_floor(char) if defined?(::Harness::Items::Loot)
          when "fled"
            parent_id = scene.location&.parent_id
            char.update!(location_id: parent_id) # nil for top-level wilderness; that's fine
          end
        end

        # Commit the wrap-up prose as a personal-scope event at the
        # abandoned location's current game_time. Catch-up sim will
        # surface it on next entry.
        prose = outcomes["summary_prose"].to_s
        return if prose.empty?

        survivors = Array(outcomes["outcomes"]).map { |o| ::Character.find_by(id: o["character_id"]) }.compact
        ::Harness::Event::ForwardAppender.append(
          game_time:    context.game_time,
          scope:        "local",
          location:     scene.location,
          details:      { "trigger" => "fight resolved without player", "details" => prose, "outcomes" => outcomes["outcomes"] },
          participants: survivors.map { |c| { character: c, role: "combatant" } }
        )
      rescue ::StandardError => e
        logger&.warn { "[Combat::PlayerFledResolution] apply failed: #{e.class}: #{e.message}" }
      end
    end
  end
end
