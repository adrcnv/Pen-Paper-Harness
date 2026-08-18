module Harness
  module Scene
    # The intra-city draw — the dice half of presence. When the player is at
    # a SUBLOCATION (a tavern, a smithy, a customs office), a free resident of
    # the same city occasionally drifts in. Without it, a sublocation only
    # ever shows its own anchored cast plus transients — a sealed room with no
    # sense of the town around it. With it, the barkeep's regulars wander in
    # for a drink and the place feels part of its city.
    #
    # The draw writes a PIN (a transient stay Whereabouts honors until the
    # next day-phase boundary) — never the location cache. Whereabouts.refresh!
    # places the pinned patron when the scene assembles; the pin lapses at the
    # phase boundary and Whereabouts resolves them onward (home or shift).
    # The candidate pool is defined by SCHEDULE, never by stored presence —
    # an off-shift keeper is drawable to the pub no matter where their row sat.
    #
    # Fires ONLY at sublocations (parent_id present). At the city tier the
    # free residents already resolve to the root, so there's nothing to draw.
    # Top-level cities are TravelerPull's domain. With no game_time (tests,
    # headless) pins are meaningless — the draw relocates the row directly,
    # matching the clockless cache-is-truth mode.
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
        # No patrons drift into a shut room — venue hours gate the draw.
        return nil if @game_time && VenueHours.closed?(@location, ::Harness::Clock.phase(@game_time))
        return nil unless @rng.rand < chance

        local = candidates.sample(random: @rng)
        return nil unless local

        if @game_time
          Whereabouts.pin!(local, @location, @game_time, logger: @logger)
        else
          local.update!(location_id: @location.id)
        end
        @logger.info { "[Scene::LocalDraw] #{local.name} of #{local.home_location&.name} drifts into #{@location.name}" }
        local
      end

      # Free residents of THIS city (anchor anywhere in the city ancestry,
      # somewhere other than this exact sublocation), not already out on a
      # pinned stay, eligible to drift in. Excludes `exclude_ids` — the cast
      # of the scene the player just left (the anti-cart rule: the person you
      # were talking to must not trail you through the next doorway). Public
      # for testability.
      def candidates
        city_ids = Residents.ancestry_ids(@location)
        scope = ::Npc.where(home_location_id: city_ids)
                     .where.not(home_location_id: @location.id)
        scope = scope.where.not(id: @exclude_ids) if @exclude_ids.any?
        scope.to_a.select { |c|
          Residents.eligible?(c) && Routine.free?(c, @game_time) &&
            !Whereabouts.pinned?(c, @game_time)
        }
      end

      private

      def chance
        @game_time.nil? ? CHANCE : PHASE_CHANCE.fetch(::Harness::Clock.phase(@game_time))
      end
    end
  end
end
