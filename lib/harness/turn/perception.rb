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
      MAX_TOKENS        = 160

      module_function

      # Observable state only: no ids, no agendas, no engine bookkeeping.
      # Deterministic construction — the same world state always digests to
      # the same string.
      def observable_view(context)
        snap  = ::Harness::Tools::QueryScene.build(context)
        looks = appearance_by_id(snap)
        borne = borne_by_id(snap)
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
          # What shows on a person: their visible activity and their standing
          # toward the player (the ladder word). The mood line is interior —
          # the voicing's, not the eyes' — and fed as `bearing` the eyes
          # narrated feelings ("eased by the prospect of help", 2026-09-12).
          "people" => Array(snap["present_characters"]).map { |c|
            { "name"        => c["name"],
              "role"        => c["subrole"],
              "gender"      => c["gender"],
              "appearance"  => looks[c["id"]],
              "carries"     => borne[c["id"]],
              "doing"       => active&.doing_for(c["id"]),
              "disposition" => active&.disposition_for(c["id"]) }.compact
          },
          "things"  => Array(snap["present_items"]).map { |i| i["name"] }.compact,
          "figures" => Array(snap["present_extras"]),
          "fallen"  => Array(snap["present_corpses"]).map { |c| c["name"] }.compact
        }.reject { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
      end

      # What of note is on a person, from their rows: a weapon, armour, a
      # jewel. The eyes painted a sword the row never had and never saw the
      # heavy dirk it did (hands run 6); a change here is a visible shift
      # like any other field. Everyday things stay unpainted.
      SIGNIFICANT_TAGS = %w[weapon armor jewelry magical].freeze
      def borne_by_id(snap)
        ids = Array(snap["present_characters"]).map { |c| c["id"] }.compact
        return {} if ids.empty?
        ::Item.where(character_id: ids).order(:id).each_with_object({}) do |i, h|
          tags = Array(i.properties.is_a?(::Hash) ? i.properties["tags"] : nil)
          next if (tags & SIGNIFICANT_TAGS).empty?
          (h[i.character_id] ||= []) << i.name
        end
      end

      # Mechanical diff between the last-rendered view and the current one:
      # people compared per person by name — a changed person appears as
      # name, role and ONLY the fields that moved (a newcomer appears whole).
      # Given the whole entry the eyes re-described the standing appearance
      # every shift (2026-09-12). Departures by name; every other top-level
      # field appears whole when it moved. Empty hash = nothing changed.
      # A disposition flip alone gives the eyes nothing to see: from
      # "hostile" and a place name they wrote three sentences of invented
      # room and named the feeling, five renders out of five (2026-09-12).
      # Doing, an arrival or departure, the hour, the things — those show;
      # disposition rides along as colour when one of them does. The stamp
      # is only advanced on a render, so an unrendered flip is still in the
      # delta when the next visible shift comes.
      def visible_shift?(delta)
        return false unless delta.is_a?(::Hash) && !delta.empty?
        return true if (delta.keys - %w[people]).any?
        Array(delta["people"]).any? { |p| (p.keys - %w[name role disposition]).any? }
      end

      def view_delta(prev, curr)
        prev ||= {}
        delta = {}
        prev_people = Array(prev["people"]).each_with_object({}) { |p, h| h[p["name"]] = p }
        curr_people = Array(curr["people"]).each_with_object({}) { |p, h| h[p["name"]] = p }
        moved = curr_people.filter_map do |name, entry|
          before = prev_people[name]
          next entry if before.nil?
          next nil if before == entry
          entry.slice("name", "role").merge(entry.reject { |k, v| %w[name role].include?(k) || before[k] == v })
        end
        gone  = prev_people.keys - curr_people.keys
        delta["people"]   = moved if moved.any?
        delta["departed"] = gone if gone.any?
        %w[place time_of_day things figures fallen].each do |k|
          delta[k] = curr[k] if prev[k] != curr[k] && curr.key?(k)
        end
        delta
      end

      # `view` is passed by the loop (it already built one for the stamp);
      # falls back to building fresh for direct callers. On a SHIFT render
      # (every turn after the establishment) the model gets the place name,
      # the hour and `changed` — what moved since the last render — and not
      # the standing room: given the whole view it re-described the same
      # two people every turn, and given its own previous prose it copied
      # it verbatim (2026-09-12). The player has already seen the room.
      # `just_now` is this turn's already-rendered parts, whole — the eyes
      # continue from what the player just read instead of contradicting it.
      # Dialogue is EXCLUDED: eyes don't hear. Quoted speech invites the
      # model to materialize talked-about things into the room (the boundary
      # wall that got rebuilt beside the tavern hearth).
      def render(context:, parts:, view: nil, changed: nil, shift_only: false, include_figures: true, logger: Rails.logger)
        view ||= observable_view(context)
        payload = if shift_only
          # The place name and the hour. The hour was dropped once (it hooked
          # an establishing opener on every shift) and the model then invented
          # one — "late afternoon light" at 10:42, three times in one run
          # (items probe 2026-09-13). A wrong fact is worse than a filler
          # opener; the opener is the prompt's job to hold.
          { "place" => (view["place"] || {}).slice("name"), "time_of_day" => view["time_of_day"] }.compact
        else
          view.dup
        end
        payload.delete("figures") unless include_figures
        payload["changed"] = changed if changed.is_a?(::Hash) && !changed.empty?
        complete_prose(context, PROMPT_PATH, payload, parts, logger)
      end

      def complete_prose(context, prompt_path, payload, parts, logger)
        llm = context.llm_nuance || context.llm_grunt
        return nil unless llm
        # The eyes must know whose skull they're in: NPC bearing/doing lines
        # legitimately reference the player in third person ("the sorcerer"),
        # and without identity the render splits the player into "you and
        # the sorcerer". Identity is dressing, not view — it can't delta.
        if (player = ::Player.first)
          payload["you"] = { "name" => player.name, "role" => player.subrole,
                             "gender" => (player.properties.is_a?(::Hash) ? player.properties["gender"] : nil) }.compact
        end
        # Eyes don't hear (dialogue) and don't read dice (bracket): shown a
        # failed Charisma bracket and no words, they narrated a head-shake
        # refusal under the very answer the quote had rendered (2026-09-12).
        just_now = Array(parts).reject { |p| %i[dialogue bracket].include?(p[:kind]) }.map { |p| p[:text] }.join("\n")
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
