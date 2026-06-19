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
    # `agenda_silent_turns` (hash: character_id => integer) counts consecutive
    # turns since the NPC last took a structural action. Reset to 0 when the
    # NPC acts (committed as actor in any propose_event / resolve this turn);
    # incremented otherwise. When the count crosses AGENDA_PUSH_THRESHOLD,
    # query_scene surfaces `agenda.push_now: true` for that character — the
    # reasoning prompt's AGENDAS rule turns that into a forced beat.
    AGENDA_PUSH_THRESHOLD = 2

    Active = Struct.new(
      :location, :snapshot, :narrations, :internal_state, :agendas, :extras, :entered_at_game_time,
      :agenda_silent_turns, :combat,
      keyword_init: true
    ) do
      def initialize(*)
        super
        self.agenda_silent_turns ||= Hash.new(0)
      end

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

      # End-of-turn bookkeeping for agenda push pressure. `acted_npc_ids` is
      # the set of NPC character_ids who appeared as `actor` in any tool
      # result this turn. NPCs with agendas who acted reset to 0; those who
      # didn't increment by 1.
      def tick_agendas!(acted_npc_ids)
        ids = (acted_npc_ids || []).map(&:to_i).to_set
        (agendas || {}).each_key do |char_id|
          if ids.include?(char_id.to_i)
            agenda_silent_turns[char_id] = 0
          else
            agenda_silent_turns[char_id] = agenda_silent_turns[char_id].to_i + 1
          end
        end
      end

      # True iff this NPC has an agenda AND it's been at least
      # AGENDA_PUSH_THRESHOLD turns since they last acted.
      def agenda_overdue?(character_id)
        return false unless (agendas || {}).key?(character_id)
        agenda_silent_turns[character_id].to_i >= AGENDA_PUSH_THRESHOLD
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
