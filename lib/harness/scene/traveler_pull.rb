module Harness
  module Scene
    # The cross-city draw. Once a location is first materialized it never
    # re-materializes (auto_target_for short-circuits), so a town's cast would
    # otherwise be frozen for the rest of the game. The traveler pull keeps
    # populated places alive: on a settlement scene entry it occasionally
    # brings in an EXISTING resident of ANOTHER city as someone passing
    # through.
    #
    # Like LocalDraw it writes a PIN, never the location cache: the visit
    # lasts until the next day-phase boundary, after which Whereabouts
    # resolves them back to their own city — travelers never accumulate, and
    # you can meet the same merchant again later at his home. With no
    # game_time the draw relocates the row directly (clockless mode).
    #
    # Peaceful townsfolk only (anchor is a settlement). A lair-anchored bandit
    # wandering into a tavern is the "bar bandit" — that waits for free-form
    # scene-contextual intent so it can behave right, and is deliberately NOT
    # done here.
    class TravelerPull
      CHANCE = 0.2 # flat fallback when no game_time is supplied; tunable knob

      # Day-phase gating: travelers arrive by daylight; the road is empty at
      # night. The timetable-lite half of "NPCs have their own hours".
      PHASE_CHANCE = { morning: 0.2, day: 0.2, evening: 0.1, night: 0.0 }.freeze

      def self.maybe_pull(location, exclude_ids: [], game_time: nil, rng: Random.new, logger: Rails.logger)
        new(location, exclude_ids: exclude_ids, game_time: game_time, rng: rng, logger: logger).maybe_pull
      end

      def initialize(location, exclude_ids: [], game_time: nil, rng: Random.new, logger: Rails.logger)
        @location    = location
        @exclude_ids = Array(exclude_ids)
        @game_time   = game_time
        @rng         = rng
        @logger      = logger
      end

      def maybe_pull
        return nil unless @location&.settlement?
        return nil unless @rng.rand < chance

        traveler = candidates.sample(random: @rng)
        return nil unless traveler

        if @game_time
          Whereabouts.pin!(traveler, @location, @game_time, logger: @logger)
        else
          traveler.update!(location_id: @location.id)
        end
        @logger.info { "[Scene::TravelerPull] #{traveler.name} of #{traveler.home_location&.name} passes through #{@location.name}" }
        traveler
      end

      # Settlement residents of ANOTHER city, awake and not held at an open
      # post (long-distance travel is itself time away from the post, so a
      # root-anchored working trade passing through mid-day is coherent — but
      # a keeper whose own venue is open right now is behind their bar, and a
      # pin could not outrank that anyway), not already out on a pinned stay —
      # minus `exclude_ids`, the cast of the scene the player just left
      # (anti-cart: nobody tails the player across cities). Public for
      # testability.
      def candidates
        here_ids = Residents.ancestry_ids(@location)
        scope = ::Npc.where.not(home_location_id: nil)
                     .where.not(home_location_id: here_ids)
        scope = scope.where.not(id: @exclude_ids) if @exclude_ids.any?
        scope.to_a.select { |c|
          Residents.eligible?(c) && Routine.awake?(c, @game_time) &&
            !post_open?(c) && !Whereabouts.pinned?(c, @game_time)
        }
      end

      private

      def post_open?(c)
        return false if @game_time.nil?
        post = Routine.post_venue(c)
        !!(post && VenueHours.open?(post, ::Harness::Clock.phase(@game_time)))
      end

      def chance
        @game_time.nil? ? CHANCE : PHASE_CHANCE.fetch(::Harness::Clock.phase(@game_time))
      end
    end
  end
end
