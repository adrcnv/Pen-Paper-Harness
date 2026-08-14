require "json"
require "digest"

module Harness
  module Turn
    # The player's EYES: paints what the player currently sees, from stored
    # scene fact — STATE, where the runner fragments render CHANGE. Appended
    # by the loop AFTER the chain and initiative settle, so it reads
    # post-commit state and every voice that spoke this turn.
    #
    # DELTA-GATED via the OBSERVABLE VIEW: `observable_view` is every field
    # the eyes can see, built fresh from state each turn (pure SQL — no LLM).
    # The view IS the diff ledger: the loop keeps {digest, view} from the
    # last render — the digest is the no-change fast path, the retained view
    # feeds `view_delta` when something moved. An establishment (arrival or
    # explicit look) renders the FULL view; a mere attribute shift renders
    # ONLY the delta — the scene is not re-established because somebody
    # coughed. ANY field added to the view — today's doing/bearing/
    # alterations, tomorrow's position-in-room — inherits both the trigger
    # and the delta render automatically; no per-attribute wiring, ever.
    # `just_now` and the establishment-only figures feed are per-render
    # dressing, not view.
    #
    # DISPLAY-ONLY by ruling: the part renders to the player but stays out of
    # the scene history buffer and every LLM payload — embellished texture
    # must not become referenceable canon (the fact-laundering intake path).
    # Everything real in the prose is readable from state by any organ, so
    # consistency doesn't depend on feeding the prose back.
    module Perception
      PROMPT_PATH       = ::File.expand_path("../prompts/perception.txt", __dir__)
      DELTA_PROMPT_PATH = ::File.expand_path("../prompts/perception_delta.txt", __dir__)
      MAX_TOKENS        = 160

      module_function

      # Observable state only: no ids, no agendas, no engine bookkeeping.
      # Deterministic construction — the same world state always digests to
      # the same string.
      def observable_view(context)
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
          # to_s: the stored view must survive a JSON roundtrip byte-identical
          # to a freshly built one, or every restore false-fires the gate.
          "time_of_day" => ::Harness::Clock.phase(context.game_time.to_i).to_s,
          "people" => Array(snap["present_characters"]).map { |c|
            { "name"       => c["name"],
              "role"       => c["subrole"],
              "gender"     => c["gender"],
              "appearance" => looks[c["id"]],
              "doing"      => active&.doing_for(c["id"]),
              "bearing"    => c["internal_state"] }.compact
          },
          "things"  => Array(snap["present_items"]).map { |i| i["name"] }.compact,
          "figures" => Array(snap["present_extras"]),
          "fallen"  => Array(snap["present_corpses"]).map { |c| c["name"] }.compact
        }.reject { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
      end

      def view_digest(view)
        ::Digest::SHA256.hexdigest(::JSON.generate(view))
      end

      # Mechanical diff between the last-rendered view and the current one:
      # people compared per person by name (a changed person appears WHOLE —
      # the delta prompt needs the who, not just the moved field), departures
      # by name; every other top-level field appears whole when it moved.
      # Empty hash = nothing observable changed.
      def view_delta(prev, curr)
        prev ||= {}
        delta = {}
        prev_people = Array(prev["people"]).each_with_object({}) { |p, h| h[p["name"]] = p }
        curr_people = Array(curr["people"]).each_with_object({}) { |p, h| h[p["name"]] = p }
        moved = curr_people.filter_map { |name, entry| entry if prev_people[name] != entry }
        gone  = prev_people.keys - curr_people.keys
        delta["people"]   = moved if moved.any?
        delta["departed"] = gone if gone.any?
        %w[place time_of_day things figures fallen].each do |k|
          delta[k] = curr[k] if prev[k] != curr[k] && curr.key?(k)
        end
        delta
      end

      # `view` is passed by the loop (it already built one for the gate);
      # falls back to building fresh for direct callers.
      # `just_now` is this turn's already-rendered parts, whole — the eyes
      # continue from what the player just read instead of contradicting it.
      # Dialogue is EXCLUDED: eyes don't hear. Quoted speech invites the
      # model to materialize talked-about things into the room (the boundary
      # wall that got rebuilt beside the tavern hearth).
      def render(context:, parts:, view: nil, include_figures: true, logger: Rails.logger)
        payload = (view || observable_view(context)).dup
        payload.delete("figures") unless include_figures
        complete_prose(context, PROMPT_PATH, payload, parts, logger)
      end

      # A mere attribute shift: the scene stays established; only the moved
      # fields (from view_delta) reach the model, anchored by the place name.
      def render_delta(context:, parts:, delta:, place: nil, logger: Rails.logger)
        return nil if delta.nil? || delta.empty?
        payload = { "place" => (place || {}).slice("name"), "changed" => delta }
        complete_prose(context, DELTA_PROMPT_PATH, payload, parts, logger)
      end

      def complete_prose(context, prompt_path, payload, parts, logger)
        llm = context.llm_nuance || context.llm_grunt
        return nil unless llm
        # The eyes must know whose skull they're in: NPC bearing/doing lines
        # legitimately reference the player in third person ("the sorcerer"),
        # and without identity the render splits the player into "you and
        # the sorcerer". Identity is dressing, not view — it can't delta.
        if (player = ::Player.first)
          payload["you"] = { "name" => player.name, "role" => player.subrole }.compact
        end
        just_now = Array(parts).reject { |p| p[:kind] == :dialogue }.map { |p| p[:text] }.join("\n")
        payload["just_now"] = just_now unless just_now.empty?
        text = ::Harness::CostTracker.in_subsystem(:perception) do
          llm.complete(
            system:     ::File.read(prompt_path),
            user:       "INPUT:\n#{JSON.pretty_generate(payload)}",
            max_tokens: MAX_TOKENS
          ).to_s.strip
        end
        text.empty? ? nil : text
      rescue StandardError => e
        logger.warn { "[Perception] render failed (#{e.class}: #{e.message}) — mechanical parts carry the turn" }
        nil
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
