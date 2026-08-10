module Harness
  module Scene
    # Snapshot of scene state at a moment — what the reasoning loop sees.
    # Transient; not persisted. Rebuild on scene transition, not mutated in place.
    Snapshot = Struct.new(
      :location, :present_characters, :present_corpses, :present_items,
      keyword_init: true
    )

    # Structural MVP — no LLM, no perception filter, no props, no tension synthesis.
    # Those are layers that sit above this once their prerequisites land.
    #
    # Rules:
    # - `present_characters` is literal to `location_id`. A character is present
    #   at the location they're at — full stop. Earlier MVP pooled siblings
    #   (same parent) under the assumption that "city sublocations are one
    #   reachable-without-travel area," but that broke down the moment we had
    #   spatially-distinct sublocations (a brewery next to a tavern; the brewer
    #   is at her brewery, not at the bar). Materializer's wake/reuse
    #   candidate pool DOES still draw from siblings + parent city (the
    #   "dormant historicals from genesis" pool spans the city) — that's
    #   a different purpose and lives in the Materializer, not here.
    # - `present_items` stays literal to `location_id`. Items are anchored;
    #   they don't wander.
    # - Path-edge adjacency was retired with the Path model. Inter-location
    #   movement is now `transition` (sibling/parent/child) or `travel`
    #   (top-level coords → coords).
    class Assembler
      def self.for(location:, game_time: nil)
        new(location, game_time: game_time).assemble
      end

      def initialize(location, game_time: nil)
        @location  = location
        @game_time = game_time
      end

      def assemble
        # A character is dead iff they were initialized (max_hp > 0) AND
        # have been zeroed (current_hp <= 0). Uninitialized rows
        # (max_hp == 0; never went through Hatchery — legacy/test fixtures)
        # count as alive: you can't die without first having been alive.
        # Dormant rows are excluded entirely — they exist structurally
        # (so event_participants can FK to them) but aren't in the scene
        # until something wakes them. See Scene::Materializer for the
        # wake path.
        scoped = ::Npc.where(location_id: @location.id).reject { |c| dormant?(c) }
        living, dead = scoped.partition { |c|
          c.max_hp.to_i <= 0 || c.current_hp.to_i > 0
        }
        Snapshot.new(
          location:           @location,
          present_characters: reject_absent(living),
          present_corpses:    dead,
          present_items:      present_items
        )
      end

      private

      def dormant?(character)
        props = character.properties
        props.is_a?(Hash) && props["dormant"] == true
      end

      # Staff keep hours. With a clock, residents of this exact spot are
      # absent outside their venue's staffed phases (VenueHours: the tavern
      # keeper works nights and sleeps of a morning; everyone else sleeps at
      # night). The row isn't moved — housing doesn't exist yet, so "where
      # they are instead" is unrepresentable; they simply aren't in the
      # scene. Followers ride with the player, and an NPC holding a due-now
      # meeting with the player waits regardless (the appointment outranks
      # the shutters). Visitors (home elsewhere) linger until the Evictor
      # runs.
      def reject_absent(living)
        return living unless @game_time
        phase = ::Harness::Clock.phase(@game_time)
        return living if VenueHours.residents_present?(@location, phase)
        keep = meet_exempt_ids
        living.reject { |c|
          c.home_location_id == @location.id && !keep.include?(c.id) && !follower?(c)
        }
      end

      def follower?(c)
        c.properties.is_a?(Hash) && c.properties["following_player"] == true
      end

      # Counterparties of an open meet with the player falling due (early by
      # the pin lead, late within the breach grace) stay visible wherever
      # they stand — same window AppointmentPin uses to place them.
      def meet_exempt_ids
        player = ::Player.first
        return [] unless player
        now = @game_time.to_i
        window = (now - ::Obligation::BREACH_GRACE)..(now + AppointmentPin::LEAD)
        ::Obligation.open_now.where(kind: "meet").involving(player.id)
          .where(due_time: window)
          .flat_map { |o| [ o.debtor_id, o.creditor_id ] }.uniq - [ player.id ]
      rescue ::StandardError
        []
      end

      def present_items
        ::Item.where(location_id: @location.id).to_a
      end
    end
  end
end
