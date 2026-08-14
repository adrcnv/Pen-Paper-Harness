require "json"

module Harness
  module Turn
    # The player's EYES: paints what the player currently sees, from stored
    # scene fact — STATE, where the runner fragments render CHANGE. Appended
    # by the loop AFTER the chain and initiative settle, so it reads
    # post-commit state and every voice that spoke this turn. Fires on every
    # non-combat turn for now (ruled; subject to a view-change gate later).
    #
    # DISPLAY-ONLY by ruling: the part renders to the player but stays out of
    # the scene history buffer and every LLM payload — embellished texture
    # must not become referenceable canon (the fact-laundering intake path).
    # Everything real in the prose is readable from state by any organ, so
    # consistency doesn't depend on feeding the prose back.
    module Perception
      PROMPT_PATH = ::File.expand_path("../prompts/perception.txt", __dir__)
      MAX_TOKENS  = 160

      module_function

      def render(context:, parts:, include_figures: true, logger: Rails.logger)
        llm = context.llm_nuance || context.llm_grunt
        return nil unless llm
        payload = build_payload(context, parts, include_figures: include_figures)
        text = ::Harness::CostTracker.in_subsystem(:perception) do
          llm.complete(
            system:     ::File.read(PROMPT_PATH),
            user:       "INPUT:\n#{JSON.pretty_generate(payload)}",
            max_tokens: MAX_TOKENS
          ).to_s.strip
        end
        text.empty? ? nil : text
      rescue StandardError => e
        logger.warn { "[Perception] render failed (#{e.class}: #{e.message}) — mechanical parts carry the turn" }
        nil
      end

      # Observable state only: no ids, no agendas, no engine bookkeeping.
      # `just_now` is this turn's already-rendered parts, whole — the eyes
      # continue from what the player just read instead of contradicting it.
      # Dialogue is EXCLUDED: eyes don't hear. Quoted speech invites the
      # model to materialize talked-about things into the room (the boundary
      # wall that got rebuilt beside the tavern hearth).
      def build_payload(context, parts, include_figures: true)
        snap  = ::Harness::Tools::QueryScene.build(context)
        looks = appearance_by_id(snap)
        # The taking-stock pass's activity microbeats live on the active
        # scene; a mid-turn move leaves the cached scene pointing at the old
        # place, so drop it then (same guard QueryScene applies).
        active = context.active_scene
        active = nil if active && active.location&.id != context.player_location&.id
        {
          "place" => {
            "name"        => snap.dig("location", "name"),
            "description" => snap.dig("location", "description"),
            "alterations" => snap.dig("location", "alterations"),
            "setting"     => snap.dig("location", "setting")
          }.compact,
          "time_of_day" => ::Harness::Clock.phase(context.game_time.to_i),
          "people" => Array(snap["present_characters"]).map { |c|
            { "name"       => c["name"],
              "role"       => c["subrole"],
              "gender"     => c["gender"],
              "appearance" => looks[c["id"]],
              "doing"      => active&.doing_for(c["id"]),
              "bearing"    => c["internal_state"] }.compact
          },
          "things"   => Array(snap["present_items"]).map { |i| i["name"] }.compact,
          "figures"  => (Array(snap["present_extras"]) if include_figures),
          "fallen"   => Array(snap["present_corpses"]).map { |c| c["name"] }.compact,
          "just_now" => Array(parts).reject { |p| p[:kind] == :dialogue }.map { |p| p[:text] }.join("\n")
        }.reject { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
      end

      def appearance_by_id(snap)
        ids = Array(snap["present_characters"]).map { |c| c["id"] }.compact
        return {} if ids.empty?
        ::Character.where(id: ids).each_with_object({}) do |ch, h|
          props = ch.properties.is_a?(Hash) ? ch.properties : {}
          look  = props["appearance"] || props["physical"]
          h[ch.id] = look if look
        end
      end
    end
  end
end
