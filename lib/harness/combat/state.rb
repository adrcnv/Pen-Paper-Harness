module Harness
  module Combat
    # In-memory state for an active combat. Lives on Scene::Active#combat,
    # nil when combat is not running. Wiped at end_combat or scene transition.
    # Not persisted — process restart = combat reset (acceptable MVP weakness;
    # see COMBAT_DESIGN.md).
    #
    # Three position buckets (engaged / near / far). Engagement is symmetric:
    # engage!(a, b) sets both sides of engaged_with and both positions to
    # "engaged". Per-round token tracking via acted_this_round / moved_this_round
    # arrays — Resolver checks these before allowing action/move tools.
    #
    # Watchers (bystander deliberation outcome = "watch") are tracked
    # separately; they're in the scene but not on a side, no initiative slot.
    # Step 8b watcher-transition rule promotes them to combatant when targeted
    # by a resolve.
    class State
      POSITIONS = %w[engaged near far].freeze

      attr_accessor :round, :initiative, :initiative_index, :last_round_summary
      attr_reader   :sides, :positions, :engaged_with,
                    :acted_this_round, :moved_this_round,
                    :watchers, :evicted_character_ids, :evicted_extras,
                    :current_round_actions

      def initialize
        @round                 = 1
        @initiative            = []
        @initiative_index      = 0
        @sides                 = {}
        @positions             = {}
        @engaged_with          = {}
        @acted_this_round      = []
        @moved_this_round      = []
        @watchers              = []
        @evicted_character_ids = []
        @evicted_extras        = []
        @last_round_summary    = nil
        # Buffer of action-hashes for the round-in-progress. Combat tools
        # append to this directly; EndOfRoundNarration reads from it; reset
        # on end_round!. Persists across run_combat yields so a round spanning
        # multiple player turns accumulates correctly.
        @current_round_actions = []
      end

      def record_action!(action)
        @current_round_actions << action
      end

      def current_actor_id
        initiative[initiative_index]
      end

      def combatant?(id)         = sides.key?(id.to_i)
      def watcher?(id)           = watchers.include?(id.to_i)
      def acted?(id)             = acted_this_round.include?(id.to_i)
      def moved?(id)             = moved_this_round.include?(id.to_i)
      def position_of(id)        = positions[id.to_i]
      def side_of(id)            = sides[id.to_i]
      def engaged_with_of(id)    = engaged_with[id.to_i]
      def slot_complete?(id)     = acted?(id) && moved?(id)
      def round_complete?        = initiative_index >= initiative.size
      def all_combatant_ids      = sides.keys

      def add_combatant(id, side:, position: "near")
        cid = id.to_i
        raise ArgumentError, "unknown position #{position.inspect}" unless POSITIONS.include?(position)
        sides[cid]     = side
        positions[cid] = position
      end

      def remove_combatant!(id)
        cid = id.to_i
        sides.delete(cid)
        positions.delete(cid)
        disengage!(cid)
        initiative.delete(cid)
        acted_this_round.delete(cid)
        moved_this_round.delete(cid)
      end

      def add_watcher(id)
        watchers << id.to_i unless watcher?(id)
      end

      def promote_watcher!(id, side:)
        cid = id.to_i
        watchers.delete(cid)
        add_combatant(cid, side: side, position: "near")
      end

      def mark_acted!(id)
        cid = id.to_i
        acted_this_round << cid unless acted?(cid)
      end

      def mark_moved!(id)
        cid = id.to_i
        moved_this_round << cid unless moved?(cid)
      end

      def set_position!(id, pos)
        cid = id.to_i
        raise ArgumentError, "unknown position #{pos.inspect}" unless POSITIONS.include?(pos)
        positions[cid] = pos
      end

      def engage!(a, b)
        ai = a.to_i
        bi = b.to_i
        engaged_with[ai] = bi
        engaged_with[bi] = ai
        positions[ai]    = "engaged"
        positions[bi]    = "engaged"
      end

      def disengage!(id)
        cid   = id.to_i
        other = engaged_with.delete(cid)
        engaged_with.delete(other) if other
      end

      def advance_slot!
        @initiative_index += 1
      end

      def end_round!
        @acted_this_round       = []
        @moved_this_round       = []
        @current_round_actions  = []
        @round                 += 1
        @initiative_index       = 0
      end

      def insert_initiative_after_current!(id)
        initiative.insert(initiative_index + 1, id.to_i)
      end

      def record_evicted_extra(description)
        evicted_extras << description
      end

      def record_evicted_character(id)
        evicted_character_ids << id.to_i
      end
    end
  end
end
