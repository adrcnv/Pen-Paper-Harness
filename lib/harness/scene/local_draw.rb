module Harness
  module Scene
    # Phase 3 of the home/current split — the intra-city twin of TravelerPull.
    #
    # TravelerPull keeps a town's cast alive by importing residents of OTHER
    # cities. LocalDraw does the same trick WITHIN a city: when the player is at
    # a SUBLOCATION (a tavern, a smithy, a customs office), a resident of the
    # same city who is currently resting at home occasionally drifts in. Without
    # it, a sublocation only ever shows its own anchored cast plus transients —
    # a sealed room with no sense of the town around it. With it, the barkeep's
    # regulars wander in for a drink and the place feels part of its city.
    #
    # Like TravelerPull it relocates an existing row (current ← here, home
    # untouched); Scene::Evictor sends them home on exit (home != here), so they
    # never accumulate and you re-meet them at their own haunt later.
    #
    # Fires ONLY at sublocations (parent_id present). At the city tier the
    # residents are already standing in the scene (home == location == here), so
    # there's nothing to draw. Top-level cities are TravelerPull's domain.
    class LocalDraw
      CHANCE = 0.25 # flat fallback when no game_time is supplied; tunable knob

      # Day-phase gating: regulars drift in mostly of an evening, rarely at
      # dawn, never in the dead of night. The timetable-lite half of "NPCs
      # have their own hours".
      PHASE_CHANCE = { morning: 0.15, day: 0.25, evening: 0.4, night: 0.0 }.freeze

      def self.maybe_draw(location, exclude_ids: [], game_time: nil, rng: Random.new, logger: Rails.logger)
        new(location, exclude_ids: exclude_ids, game_time: game_time, rng: rng, logger: logger).maybe_draw
      end

      def initialize(location, exclude_ids: [], game_time: nil, rng: Random.new, logger: Rails.logger)
        @location    = location
        @exclude_ids = Array(exclude_ids)
        @game_time   = game_time
        @rng         = rng
        @logger      = logger
      end

      def maybe_draw
        return nil unless @location&.parent_id   # sublocations only
        return nil unless @location.settlement?   # not a wilderness-leaf sub
        return nil unless @rng.rand < chance

        local = candidates.sample(random: @rng)
        return nil unless local

        local.update!(location_id: @location.id)
        @logger.info { "[Scene::LocalDraw] #{local.name} of #{local.home_location&.name} drifts into #{@location.name}" }
        local
      end

      # Residents of THIS city (home anywhere in the city ancestry) whose home
      # is somewhere OTHER than this exact sublocation, currently resting at
      # home, eligible to drift in. Excludes this sublocation's own residents
      # (already here), anyone currently away from home (already out and
      # about), and `exclude_ids` — the cast of the scene the player just left
      # (the anti-cart rule: the person you were talking to must not trail you
      # through the next doorway). Public for testability.
      def candidates
        city_ids = Residents.ancestry_ids(@location)
        scope = ::Npc.where(home_location_id: city_ids)
                     .where.not(home_location_id: @location.id)
                     .where("characters.location_id = characters.home_location_id") # resting at home
        scope = scope.where.not(id: @exclude_ids) if @exclude_ids.any?
        scope.to_a.select { |c| Residents.eligible?(c) && Routine.free?(c, @game_time) }
      end

      private

      def chance
        @game_time.nil? ? CHANCE : PHASE_CHANCE.fetch(::Harness::Clock.phase(@game_time))
      end
    end
  end
end
