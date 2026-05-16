module Harness
  module Event
    module PreFilter
      # Narrows the event log to events that occurred strictly AFTER a given
      # game_time and could plausibly constrain a backward-append at that time.
      # Two channels:
      #   1. Location scope — events at the proposed location, its same-parent
      #      siblings, and its ancestor chain. Mirrors the assembler's presence
      #      scope (a sublocation has its parent city's events visible).
      #   2. Participant — events involving any of the proposed character
      #      participants (continuity of person).
      #
      # Capped at DEFAULT_LIMIT to bound the validator's input size. Hard cap
      # is more honest than soft "could be N events" — pre-filter is a
      # context budget, not a guarantee.
      class After
        DEFAULT_LIMIT = 50

        def self.events(game_time:, location:, participants: [], limit: DEFAULT_LIMIT)
          new(game_time, location, participants, limit).events
        end

        def initialize(game_time, location, participants, limit)
          @game_time    = game_time
          @location     = location
          @participants = Array(participants)
          @limit        = limit
        end

        def events
          ids = location_event_ids | participant_event_ids
          ::Event.where(id: ids)
                 .where("game_time > ?", @game_time)
                 .order(:game_time, :id)
                 .limit(@limit)
        end

        private

        def location_event_ids
          return [] unless @location
          ::Event.where(location_id: location_scope_ids).pluck(:id)
        end

        # Same-parent siblings + ancestor chain.
        def location_scope_ids
          sibling_ids = if @location.parent_id
            ::Location.where(parent_id: @location.parent_id).pluck(:id)
          else
            [ @location.id ]
          end
          ancestor_ids = ancestor_chain(@location.parent)
          (sibling_ids + ancestor_ids).uniq
        end

        def ancestor_chain(loc)
          ids = []
          current = loc
          while current
            ids << current.id
            current = current.parent
          end
          ids
        end

        def participant_event_ids
          return [] if @participants.empty?
          char_ids = @participants.map(&:id)
          ::EventParticipant.where(character_id: char_ids).pluck(:event_id)
        end
      end
    end
  end
end
