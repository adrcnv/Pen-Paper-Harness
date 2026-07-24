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
      :combat, :initiative_cooldown, :last_initiator, :spoken_ids, :last_lines, :contest_ledger,
      :dispositions,
      keyword_init: true
    ) do
      # The disposition ladder — each NPC's standing temperature toward the
      # player, scene-scoped. Descriptive context ONLY, never a trigger. The
      # post-emit reevaluation moves it at most one step per turn; internal
      # state (the mood flavor line) rides beside it and is no longer frozen
      # at the seeded value — the taking-stock pass refreshes both.
      DISPOSITIONS = %w[hostile guarded neutral warm trusting].freeze

      # Has this character already taken a speaking turn in THIS scene? Once
      # they've spoken, the live thread carries their words — but mood/agenda
      # are NO longer dropped with it: the reevaluation pass keeps them
      # current, so a stale seed can't yank a mid-conversation NPC backwards.
      def spoken?(character_id)
        (spoken_ids || []).include?(character_id)
      end

      def disposition_for(character_id)
        (dispositions || {})[character_id] || "neutral"
      end

      # One ladder step, clamped at the ends. direction: "warmer" | "colder".
      def shift_disposition!(character_id, direction)
        idx = DISPOSITIONS.index(disposition_for(character_id)) || 2
        idx += (direction == "warmer" ? 1 : -1)
        self.dispositions ||= {}
        dispositions[character_id] = DISPOSITIONS[idx.clamp(0, DISPOSITIONS.size - 1)]
      end

      def update_state!(character_id, mood_line)
        self.internal_state ||= {}
        internal_state[character_id] = mood_line
      end

      def clear_agenda!(character_id)
        (agendas || {}).delete(character_id)
      end

      def mark_spoken!(character_id)
        self.spoken_ids ||= []
        spoken_ids << character_id unless spoken_ids.include?(character_id)
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

      # Scene-scoped contest ledger: one roll per (target, kind) per scene —
      # a repeat attempt reuses the standing verdict instead of rerolling
      # (you don't get to re-ask the same question harder; also kills the
      # reroll-until-crit / XP farm). Key "target_id:kind"; dies with the scene.
      def contest_for(key)
        (contest_ledger || {})[key]
      end

      def record_contest!(key, payload)
        self.contest_ledger ||= {}
        contest_ledger[key] = payload
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
