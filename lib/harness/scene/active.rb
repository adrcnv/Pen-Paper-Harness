module Harness
  module Scene
    # In-memory state for the currently-playing scene. Holds the location,
    # the assembled snapshot, and the running list of (input, narration)
    # pairs from this scene's turns. Wiped at scene transition; the next
    # scene gets a fresh Active.
    #
    # Not persisted today. TurnLog rows hold durable per-turn copies; if a
    # session crashes mid-scene, the in-memory list is lost (extraction for
    # that scene gets skipped on next launch). Acceptable MVP weakness;
    # future `conversations` table can rebuild from TurnLog by scene_id.
    #
    # `agendas` (hash: character_id => text) holds at most one per scene — the
    # player-targeted GOAL/FRICTION seed from Scene::InternalState. It's inert
    # CONTENT: surfaced as scene context, consumed by nothing here. The
    # decision of WHEN an NPC acts on an agenda belongs to the (forthcoming)
    # initiative pass, not to a silent-turn counter on this struct. The old
    # push-pressure machinery (silent-turn ticking / overdue / push_now) was
    # removed precisely to avoid two places deciding initiative timing.
    # `initiative_cooldown` (int) + `initiative_pushes` (char_id => count) are
    # the Scene::Initiative pass's OWN scene-scoped bookkeeping — cadence gate
    # and per-agenda push count (for escalation). Not surfaced to query_scene,
    # not the old per-character pressure that was torn out; this is the single
    # place the pass tracks timing, and it dies with the scene.
    Active = Struct.new(
      :location, :snapshot, :narrations, :internal_state, :agendas, :extras, :entered_at_game_time,
      :combat, :initiative_cooldown, :initiative_pushes,
      keyword_init: true
    ) do
      # Combat sub-mode helpers. `combat` is nil when no fight is running; set
      # by Tools::StartCombat, cleared by Combat::Loop's end_combat!. While
      # set, the resolver serves the narrow combat-mode tool surface (see
      # COMBAT_DESIGN.md).
      def in_combat?
        !combat.nil?
      end

      def start_combat!
        self.combat = ::Harness::Combat::State.new
      end

      def end_combat!
        self.combat = nil
      end

      def append_narration(input, narration)
        narrations << { "input" => input, "narration" => narration }
      end

      # Returns the prose line for this character_id, or nil if not generated
      # (no LLM available, character not present at scene entry, or
      # generation skipped).
      def state_for(character_id)
        (internal_state || {})[character_id]
      end

      # Returns this character's scene agenda text, or nil if they have none.
      # At most ONE NPC in any scene has an agenda — the LLM picks the most
      # plausible candidate at scene-entry, often picking nobody. Agenda
      # persists for the whole scene (no per-turn consumption — the
      # reasoning loop reads it each turn and decides whether to push).
      def agenda_for(character_id)
        (agendas || {})[character_id]
      end

      def present_characters
        snapshot&.present_characters || []
      end

      # Dead NPCs still anchored to this location — bodies on the floor.
      # Surfaced separately so they're inert as action targets but still
      # available to narration ("his body slumps against the wall") and to
      # pickup of items dropped at death (Tools::Pickup uses the location-
      # anchored items, not these rows directly).
      def present_corpses
        snapshot&.present_corpses || []
      end

      def present_items
        snapshot&.present_items || []
      end

      # Ambient nameless figures painted into the scene at entry — pure
      # narration flavor. Array of one-line descriptions. No ids; cannot be
      # commit targets. If the player engages an extra consequentially, the
      # reasoning loop calls propose_character to materialize them as a real
      # Npc row (the description carries forward via the connection arg).
      def present_extras
        extras || []
      end
    end
  end
end
