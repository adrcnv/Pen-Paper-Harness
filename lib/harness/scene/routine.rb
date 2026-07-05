module Harness
  module Scene
    # Mechanical NPC routine — presence-eligibility as a PURE FUNCTION of
    # subrole + Clock.phase. No stored schedule, no LLM: viable since the
    # 07-03 reshape made subrole a closed Vocations noun (free-text strays
    # from genesis fall into the default bucket).
    #
    # Three states:
    #   :working — on shift, at their post (their home sublocation IS their
    #              workplace); not drawable elsewhere.
    #   :free    — off shift; the draw pool. This is how the town smith turns
    #              up at the pub of an evening.
    #   :off     — night; drawable nowhere.
    #
    # Consumers today: LocalDraw (requires :free) and TravelerPull (requires
    # not-:off — long-distance travel is itself time away from the post, so a
    # working trade passing through another town mid-day is coherent).
    # A future LLM-authored per-NPC schedule can override this default via
    # properties; this table is the floor, not the ceiling.
    module Routine
      DEFAULT_WORK = [ :morning, :day ].freeze

      # Vocations whose shift differs from the default day-trade. Everything
      # not listed (and any free-text stray) works morning+day.
      WORK_BLOCKS = {
        "barkeep"   => [ :day, :evening ].freeze,
        "innkeeper" => [ :morning, :day, :evening ].freeze,
        "cook"      => [ :day, :evening ].freeze,
        "minstrel"  => [ :evening ].freeze,
        "guard"     => [ :day, :evening ].freeze,
        "priest"    => [ :morning, :evening ].freeze,
        # Itinerants and idlers — no post to hold, free whenever awake.
        "bandit"    => [].freeze,
        "mercenary" => [].freeze,
        "hermit"    => [].freeze,
        "pilgrim"   => [].freeze,
        "wanderer"  => [].freeze,
        "beggar"    => [].freeze
      }.freeze

      module_function

      def state(character, game_time)
        phase = ::Harness::Clock.phase(game_time)
        return :off if phase == :night
        WORK_BLOCKS.fetch(character.subrole.to_s, DEFAULT_WORK).include?(phase) ? :working : :free
      end

      # nil game_time = no clock in play (tests, headless) → no routine gate.
      def free?(character, game_time)
        game_time.nil? || state(character, game_time) == :free
      end

      def awake?(character, game_time)
        game_time.nil? || state(character, game_time) != :off
      end
    end
  end
end
