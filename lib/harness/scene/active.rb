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
    # `agendas` (hash: character_id => text) holds ONE PER PRESENT CHARACTER
    # that has a live angle toward the player — the GOAL/FRICTION seed from
    # Scene::InternalState. It's inert CONTENT: surfaced as scene context,
    # consumed by the post-narration Scene::Initiative consumer, which reads
    # the agendas + the turn's narration and decides whether ONE character acts
    # this turn. `initiative_cooldown` (int) is the pass's own scene-scoped
    # arrival-settle gate (skip the turn the scene is entered); `last_initiator`
    # (char_id) is the previous turn's actor, lightly avoided so the room
    # rotates. Both die with the scene.
    Active = Struct.new(
      :location, :snapshot, :narrations, :internal_state, :agendas, :extras, :entered_at_game_time,
      :combat, :initiative_cooldown, :last_initiator, :spoken_ids, :last_lines, :last_speaker_ids,
      keyword_init: true
    ) do
      # Has this character already taken a speaking turn in THIS scene? Seeded
      # mood/agenda steer an NPC's OPENING stance; once they've spoken, the live
      # conversation thread carries them and the frozen self-state is dropped (it
      # otherwise fights the evolving exchange — an NPC yanked back to a
      # pre-conversation stance reads as fickle). Consumed by the conversation
      # runner + Scene::Initiative, both of which strip mood/agenda for spoken NPCs.
      def spoken?(character_id)
        (spoken_ids || []).include?(character_id)
      end

      def mark_spoken!(character_id)
        self.spoken_ids ||= []
        spoken_ids << character_id unless spoken_ids.include?(character_id)
      end

      # Who spoke on the PREVIOUS conversation turn — the bystander-cooldown's
      # memory (conversation runner: an unaddressed NPC that chimed in last
      # turn is not polled again this turn, so nobody nags every single turn).
      def spoke_last_turn?(character_id)
        (last_speaker_ids || []).include?(character_id)
      end

      def record_speakers!(ids)
        self.last_speaker_ids = ids
      end

      # Each character's most recent staged dialogue line this scene — the
      # repeat-guard's memory (the weak model, shown its own labeled prior
      # line in the thread, re-emits it near-verbatim; the guard suppresses
      # the parrot so the character breaks off instead).
      def last_line_for(character_id)
        (last_lines || {})[character_id]
      end

      def record_line!(character_id, prose)
        self.last_lines ||= {}
        last_lines[character_id] = prose
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

      # Returns the prose line for this character_id, or nil if not generated
      # (no LLM available, character not present at scene entry, or
      # generation skipped).
      def state_for(character_id)
        (internal_state || {})[character_id]
      end

      # Returns this character's scene agenda text (their standing angle toward
      # the player), or nil if they have none. Seeded per present character at
      # scene-entry; persists for the whole scene. The post-narration
      # Scene::Initiative consumer reads these to decide who, if anyone, acts.
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
