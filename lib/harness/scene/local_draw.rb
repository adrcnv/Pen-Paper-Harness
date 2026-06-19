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
      CHANCE = 0.25 # per sublocation scene entry; tunable knob

      def self.maybe_draw(location, rng: Random.new, logger: Rails.logger)
        new(location, rng: rng, logger: logger).maybe_draw
      end

      def initialize(location, rng: Random.new, logger: Rails.logger)
        @location = location
        @rng      = rng
        @logger   = logger
      end

      def maybe_draw
        return nil unless @location&.parent_id   # sublocations only
        return nil unless @location.settlement?   # not a wilderness-leaf sub
        return nil unless @rng.rand < CHANCE

        local = candidates.sample(random: @rng)
        return nil unless local

        local.update!(location_id: @location.id)
        @logger.info { "[Scene::LocalDraw] #{local.name} of #{local.home_location&.name} drifts into #{@location.name}" }
        local
      end

      # Residents of THIS city (home anywhere in the city ancestry) whose home
      # is somewhere OTHER than this exact sublocation, currently resting at
      # home, eligible to drift in. Excludes this sublocation's own residents
      # (already here) and anyone currently away from home (already out and
      # about). Public for testability.
      def candidates
        city_ids = Residents.ancestry_ids(@location)
        ::Npc.where(home_location_id: city_ids)
             .where.not(home_location_id: @location.id)
             .where("characters.location_id = characters.home_location_id") # resting at home
             .to_a
             .select { |c| Residents.eligible?(c) }
      end
    end
  end
end
