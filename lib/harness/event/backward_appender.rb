module Harness
  module Event
    # Inserts one or more events into past history, atomically. Validates the
    # proposed CLUSTER (N=1 to N=many) for internal consistency AND consistency
    # with the structurally-narrowed set of existing events that already
    # happened in the cluster's time window or at related locations. On accept
    # commits all events in one transaction; on reject raises Rejected with
    # free-text reasons.
    #
    # Pure validator semantics — accept (commit) or reject (raise). No
    # logical-retry loop here; rerunning the validator on the same proposal
    # almost certainly produces the same answer. Callers (e.g. Genesis) own
    # the regenerate-with-feedback retry policy.
    #
    # Hydrator-shape failures DO retry (default 1) — the validator might have
    # produced malformed JSON; one fix-attempt is cheap.
    #
    # Two callers (both wired):
    #   1. Reasoning-loop narrative shift via propose_event tool (N=1)
    #   2. Genesis::Generator at propose_location wilderness_leaf (N=1..many)
    #
    # Floor enforcement: each event in the cluster must have game_time ≥ each
    # of its character participants' earliest existing event game_time.
    # Post-Phase-2: ALL participants are class-4 (Genesis eager-spawns
    # dormant rows for its named historicals; narrative-shift always
    # carried class-4). For genesis-spawned rows the character has zero
    # prior events so the floor is unbounded — the backstory cluster
    # itself sets it.
    #
    # Idempotency: not enforced. Identical successful payloads create multiple
    # rows. LLM is responsible for not double-calling.
    class BackwardAppender
      class FloorViolation < StandardError
        attr_reader :participant, :floor_game_time, :event_index
        def initialize(participant, floor_game_time, proposed_game_time, event_index: nil)
          @participant     = participant
          @floor_game_time = floor_game_time
          @event_index     = event_index
          where = event_index ? "events[#{event_index}] " : ""
          super(
            "#{where}proposed game_time=#{proposed_game_time} is below participant " \
            "#{participant.name}'s earliest event at game_time=#{floor_game_time}"
          )
        end
      end

      class Rejected < StandardError
        attr_reader :reasons
        def initialize(reasons)
          @reasons = Array(reasons)
          super("backward-append rejected: #{@reasons.join('; ')}")
        end
      end

      attr_reader :logger

      Result = Struct.new(:events, :after_event_count, :validator_called, keyword_init: true)

      def self.append(**kwargs)
        new(**kwargs).append
      end

      def initialize(events:, llm_client:, logger: Rails.logger, max_retries: 1, pre_filter_limit: ::Harness::Event::PreFilter::After::DEFAULT_LIMIT)
        @events           = events
        @llm              = llm_client
        @logger           = logger
        @max_retries      = max_retries
        @pre_filter_limit = pre_filter_limit
      end

      def append
        raise ArgumentError, "events must be a non-empty array" unless @events.is_a?(Array) && @events.any?

        validate_floor!

        after_events = build_after_set
        validator_called = false

        # Validator runs whenever there's something it could meaningfully
        # check: more than one event in the cluster (internal consistency) OR
        # any existing events in the after-set (cross-event consistency).
        # Single-event cluster with empty after-set is trivially consistent;
        # skip the LLM call.
        needs_validation = @events.size > 1 || after_events.any?

        if needs_validation
          if @llm.nil?
            raise Rejected.new([ "no llm_grunt configured for cluster validator" ])
          end
          judgment = call_validator(after_events)
          validator_called = true

          unless judgment["consistent"]
            raise Rejected.new(judgment["reasons"])
          end
        end

        committed = commit
        Result.new(events: committed, after_event_count: after_events.size, validator_called: validator_called)
      end

      private

      # Floor = "the character must have existed in the world by game_time T to be
      # a participant at T." Computed as the earliest NARRATIVE event the character
      # was a participant in. Intro events (the audit-only events propose_character/
      # faction/item/location auto-create) are EXCLUDED via Event.narrative — they
      # record "this row was created in-game" not "this character started existing."
      # Including them as floor would prevent legitimate backstory: a character
      # introduced just now couldn't have a history dating back years, even though
      # in-world they obviously did.
      def validate_floor!
        @events.each_with_index do |event, idx|
          Array(event[:participants]).each do |p|
            char = p[:character]
            next unless char
            floor = ::EventParticipant.joins(:event)
                                      .merge(::Event.narrative)
                                      .where(character_id: char.id)
                                      .minimum("events.game_time")
            next if floor.nil?
            if event[:game_time] < floor
              raise FloorViolation.new(char, floor, event[:game_time], event_index: (@events.size > 1 ? idx : nil))
            end
          end
        end
      end

      # After-set spans the cluster's earliest game_time, narrowed structurally
      # to the union of all event locations + all class-4 participants. For
      # single-location clusters (genesis: all events at the new location;
      # narrative-shift: one event at the player's scene) this collapses to
      # the existing PreFilter::After behavior. Cross-location clusters use
      # the first event's location as the ancestor-chain anchor — accepted
      # limitation; deferred until a cross-location use case appears.
      def build_after_set
        floor = @events.map { |e| e[:game_time] }.min
        anchor_location = @events.map { |e| e[:location] }.find { |l| l.is_a?(::Location) }
        characters = @events.flat_map { |e| Array(e[:participants]).map { |p| p[:character] } }.compact.uniq

        ::Harness::Event::PreFilter::After.events(
          game_time:    floor,
          location:     anchor_location,
          participants: characters,
          limit:        @pre_filter_limit
        ).to_a
      end

      # Commit ordered by game_time so the log reads chronologically. All
      # events go through ForwardAppender (the row-insert primitive) inside
      # one outer transaction — any failure aborts the whole cluster.
      def commit
        committed = []
        ::ActiveRecord::Base.transaction do
          @events.sort_by { |e| e[:game_time] }.each do |e|
            committed << ::Harness::Event::ForwardAppender.append(
              game_time:           e[:game_time],
              scope:               e[:scope],
              location:            e[:location],
              details:             e[:details] || {},
              participants:        Array(e[:participants]),
              references_event_id: e[:references_event_id]
            )
          end
        end
        logger.info { "[BackwardAppender] committed cluster of #{committed.size} event(s)" }
        committed
      end

      def call_validator(after_events)
        attempts = 0
        prompt = Prompt.render(events: @events, after_events: after_events)
        current_user = prompt[:user]

        loop do
          attempts += 1
          logger.debug { "[BackwardAppender] validator LLM call attempt #{attempts}" }

          raw = ::Harness::CostTracker.in_subsystem(:backward_appender_validator) {
            @llm.complete(system: prompt[:system], user: current_user)
          }
          logger.debug { "[BackwardAppender] raw output (attempt #{attempts}, #{raw.size} bytes):\n#{raw}" }

          begin
            return Hydrator.hydrate(llm_output: raw)
          rescue Hydrator::InvalidOutput => e
            logger.warn { "[BackwardAppender] validator output invalid (attempt #{attempts}/#{@max_retries + 1}): #{e.errors.join('; ')}" }
            raise if attempts > @max_retries

            current_user = repair_user(prompt[:user], raw, e.errors)
          end
        end
      end

      def repair_user(original_user, bad_output, errors)
        <<~REPAIR
          #{original_user}

          YOUR PREVIOUS OUTPUT WAS REJECTED. Here is what you produced:
          #{bad_output}

          ERRORS:
          #{errors.map { |e| "- #{e}" }.join("\n")}

          Fix ALL errors and output the corrected JSON. Follow the HARD RULES exactly.
        REPAIR
      end
    end
  end
end
