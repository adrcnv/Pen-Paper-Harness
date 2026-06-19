module Harness
  module Scene
    # Phase 2 of the home/current split. Once a location is first materialized
    # it never re-materializes (auto_target_for short-circuits on any active
    # NPC), so a town's cast would otherwise be frozen for the rest of the game.
    # The traveler pull keeps populated places alive: on a settlement scene
    # entry it occasionally relocates an EXISTING resident of ANOTHER city —
    # currently resting at home — into the scene as someone passing through.
    #
    # Because it reuses a real row (current ← here, home untouched), the world
    # gains continuity: you can meet the same merchant again later in his own
    # city. On scene exit, Scene::Evictor sends them home (home != here), so
    # travelers never accumulate.
    #
    # Peaceful townsfolk only (home is a settlement). A lair-homed bandit
    # wandering into a tavern is the "bar bandit" — that waits for free-form
    # scene-contextual intent so it can behave right, and is deliberately NOT
    # done here.
    class TravelerPull
      CHANCE = 0.2 # per settlement scene entry; tunable knob

      def self.maybe_pull(location, rng: Random.new, logger: Rails.logger)
        new(location, rng: rng, logger: logger).maybe_pull
      end

      def initialize(location, rng: Random.new, logger: Rails.logger)
        @location = location
        @rng      = rng
        @logger   = logger
      end

      def maybe_pull
        return nil unless @location&.settlement?
        return nil unless @rng.rand < CHANCE

        traveler = candidates.sample(random: @rng)
        return nil unless traveler

        traveler.update!(location_id: @location.id)
        @logger.info { "[Scene::TravelerPull] #{traveler.name} of #{traveler.home_location&.name} passes through #{@location.name}" }
        traveler
      end

      # Existing settlement residents of ANOTHER city, currently resting at
      # home, eligible to wander in. Public for testability (the selection is
      # the load-bearing part; the dice roll is just a gate).
      def candidates
        here_ids = Residents.ancestry_ids(@location)
        ::Npc.where.not(home_location_id: nil)
             .where.not(home_location_id: here_ids)
             .where("characters.location_id = characters.home_location_id") # resting at home
             .to_a
             .select { |c| Residents.eligible?(c) }
      end
    end
  end
end
