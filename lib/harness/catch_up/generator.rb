module Harness
  module CatchUp
    # Catch-up = "fill in what happened here while the player was elsewhere."
    # Fired by Scene::Manager.enter when:
    #   - llm_grunt is configured
    #   - the location has prior events (otherwise this is Genesis territory,
    #     or a fresh sublocation with nothing to catch up on)
    #   - the gap between the location's most recent event and current game_time
    #     exceeds MIN_GAP (otherwise: nothing meaningful would have happened)
    #
    # Pipeline:
    #   1. Compute floor = max(events.game_time at this location).
    #   2. Generator LLM call → 0-5 ambient events in the gap window.
    #   3. ForwardAppender.append per event in one transaction.
    #
    # Differs from Genesis in three ways:
    #   - Uses ForwardAppender (catch-up events have nothing later to contradict
    #     in their own time window — by definition the gap had no events here).
    #   - Participants are RESTRICTED to existing class-4 names at this
    #     location. Post-Phase-2, no class-2 fallback exists — and catch-up
    #     does NOT eager-spawn fresh characters the way Genesis does. The
    #     LLM picks from the existing local cast or produces zero events.
    #     Names of characters at OTHER locations are explicitly forbidden.
    #   - Scope = "local" exclusively. Regional+ during the gap is the spine
    #     sim's job; catch-up stays at the place's own scale.
    #
    # Failure handling:
    #   - LLM unavailable    → caller skips (we never get called)
    #   - Hydrator failure   → 1 retry with parse errors as feedback, then []
    #   - ForwardAppender::InvalidEvent → log warning, continue with the rest
    #
    # Returns the array of committed Event rows (possibly empty).
    class Generator
      MIN_GAP                = 100
      MAX_GENERATOR_RETRIES  = 1
      RECENT_ACTORS_LIMIT    = 5
      RECENT_EVENTS_LIMIT    = 5
      SCENARIO_TABLE         = "catch_up"

      attr_reader :logger

      def initialize(llm_client:, logger: Rails.logger, max_retries: MAX_GENERATOR_RETRIES, min_gap: MIN_GAP, rng: Random.new)
        @llm         = llm_client
        @logger      = logger
        @max_retries = max_retries
        @min_gap     = min_gap
        @rng         = rng
      end

      def generate(location:, current_game_time:)
        return [] unless @llm

        ::Harness::CostTracker.in_subsystem(:catch_up) do
          generate_inner(location: location, current_game_time: current_game_time)
        end
      end

      private

      def generate_inner(location:, current_game_time:)
        floor = ::Event.where(location_id: location.id).maximum(:game_time)
        if floor.nil?
          logger.info { "[CatchUp::Generator] location=#{location.name} has no prior events; skipped (Genesis territory)" }
          return []
        end

        gap = current_game_time - floor
        if gap < @min_gap
          logger.info { "[CatchUp::Generator] location=#{location.name} gap=#{gap} below MIN_GAP=#{@min_gap}; skipped" }
          return []
        end

        scenario = ::Harness::Scenarios::Roller.roll(
          table:   SCENARIO_TABLE,
          context: { biome: location.biome },
          rng:     @rng
        )
        logger.info { "[CatchUp::Generator] scenario rolled for #{location.name}: #{scenario.id}" }

        actors = recent_actors_for(location)
        recent = recent_events_for(location)
        logger.info { "[CatchUp::Generator] location=#{location.name} floor=#{floor} current=#{current_game_time} gap=#{gap} recent_actors=#{actors.size} recent_events=#{recent.size}" }

        # Post-Phase-2 invariant: catch-up may ONLY reference characters who
        # are class-4 rows AT this location AND not dormant AND not following
        # the player. Anything else either doesn't exist yet (would need
        # eager Hatchery, which catch-up doesn't do) or belongs elsewhere
        # (cross-location identity collision risk).
        allowed_names = ::Npc.where(location_id: location.id)
                             .reject { |c|
                               props = c.properties
                               next true unless props.is_a?(Hash)
                               props["dormant"] == true || props["following_player"] == true
                             }
                             .map(&:name)
                             .compact
                             .to_set

        events_payload = call_generator(
          location:          location,
          current_game_time: current_game_time,
          floor_game_time:   floor,
          recent_actors:     actors,
          recent_events:     recent,
          scenario_seed:     scenario.prompt_seed,
          allowed_names:     allowed_names
        )

        if events_payload.empty?
          logger.info { "[CatchUp::Generator] generator returned 0 events for #{location.name}; nothing to commit" }
          return []
        end

        commit(events_payload, location)
      end

      private

      def commit(events_payload, location)
        committed = []
        ::ActiveRecord::Base.transaction do
          existing_by_name = lookup_existing_characters(events_payload, location)
          events_payload.sort_by { |e| e["game_time"] }.each do |e|
            participants = e["participants"].map { |p|
              name = p["actor_name"]
              char = existing_by_name[name]
              { character: char, role: p["role"] } if char
            }.compact
            # If any participant name didn't resolve, the hydrator should
            # have already rejected — but defensive: skip the event rather
            # than crash on an invalid participant set.
            if participants.size != e["participants"].size
              logger.warn { "[CatchUp::Generator] dropping event at gt=#{e['game_time']} — participant name(s) didn't resolve to class-4 rows at this location" }
              next
            end

            begin
              committed << ::Harness::Event::ForwardAppender.append(
                game_time:    e["game_time"],
                scope:        e["scope"],
                location:     location,
                details:      e["details"],
                participants: participants
              )
            rescue ::Harness::Event::ForwardAppender::InvalidEvent => err
              logger.warn { "[CatchUp::Generator] dropped invalid event at gt=#{e['game_time']}: #{err.message}" }
            end
          end
        end
        actor_names = committed.flat_map { |ev| ev.event_participants.map { |ep| ep.character&.name }.compact }.uniq
        logger.info { "[CatchUp::Generator] committed=#{committed.size} for #{location.name} actors=#{actor_names}" }
        committed
      end

      # Look up the class-4 rows for every name in the cluster. Hydrator
      # has already rejected anything outside the allowed_names set, so
      # this should resolve every name; the commit step's
      # participant-count check catches any edge cases anyway.
      def lookup_existing_characters(events_payload, location)
        names = events_payload
                  .flat_map { |e| Array(e["participants"]).map { |p| p["actor_name"] } }
                  .compact
                  .map(&:strip)
                  .reject(&:empty?)
                  .uniq
        return {} if names.empty?
        ::Npc.where(location_id: location.id, name: names)
             .each_with_object({}) { |npc, h| h[npc.name] = npc }
      end

      def call_generator(location:, current_game_time:, floor_game_time:, recent_actors:, recent_events:, scenario_seed:, allowed_names:)
        prompt = Prompt.render(
          location_name:     location.name,
          description:       location.description,
          parent_name:       location.parent&.name,
          biome:             location.biome,
          # Economic identity (terrain/basis/size/wealth) so background-sim
          # events fit what the place lives on instead of generic flavor.
          setting:           ::Harness::Settlement::Facts.presentable(location),
          current_game_time: current_game_time,
          floor_game_time:   floor_game_time,
          recent_actors:     recent_actors,
          recent_events:     recent_events,
          scenario_seed:     scenario_seed
        )
        current_user = prompt[:user]

        attempts = 0
        loop do
          attempts += 1
          logger.debug { "[CatchUp::Generator] generator LLM call attempt #{attempts}" }

          raw = @llm.complete(system: prompt[:system], user: current_user)
          logger.debug { "[CatchUp::Generator] raw output (attempt #{attempts}, #{raw.size} bytes):\n#{raw}" }

          begin
            return Hydrator.hydrate(
              llm_output:        raw,
              current_game_time: current_game_time,
              floor_game_time:   floor_game_time,
              allowed_names:     allowed_names
            )
          rescue Hydrator::InvalidOutput => e
            logger.warn { "[CatchUp::Generator] generator output invalid (attempt #{attempts}): #{e.errors.join('; ')}" }
            return [] if attempts > @max_retries
            current_user = "#{current_user}\n\n#{retry_feedback(e.errors, allowed_names)}"
          end
        end
      end

      # On retry, surface the allowed-names set explicitly. Common case
      # (no rejection) adds zero tokens.
      def retry_feedback(errors, allowed_names)
        msg = +"YOUR PREVIOUS OUTPUT WAS REJECTED. Errors:\n"
        msg << errors.map { |x| "- #{x}" }.join("\n")
        if allowed_names.any?
          msg << "\n\nPARTICIPANTS MUST BE ONE OF THESE EXISTING CHARACTERS AT THIS LOCATION:\n"
          msg << allowed_names.to_a.sort.join(", ")
        else
          msg << "\n\nNO CHARACTERS LIVE AT THIS LOCATION YET. You cannot name any participant — either produce zero events, or only describe ambient activity in `details` prose with no participants."
        end
        msg << "\n\nFix and resubmit."
        msg
      end

      # Pulls characters living at this location with the most local event
      # participation, so the LLM can prefer reuse over inventing fresh names.
      #
      # EXCLUDES:
      # - Current followers (`properties.following_player == true`): their
      #   location_id matches the player's, so they're technically here now,
      #   but in-fiction they were walking WITH the player, not solo during
      #   the gap. Surfacing them lets CatchUp invent events like "Elara
      #   came through last week and shared stories" — bogus, since she
      #   was with the player elsewhere.
      # - Dormant historicals (`properties.dormant == true`): genesis-era
      #   named participants. They don't act in the current window — they
      #   wake when Scene::Materializer picks them at scene entry. Without
      #   this filter, CatchUp would happily generate events featuring
      #   characters who structurally shouldn't be in play yet.
      def recent_actors_for(location)
        skip_ids = ::Npc.where(location_id: location.id)
                        .select { |c|
                          props = c.properties
                          next false unless props.is_a?(Hash)
                          props["following_player"] == true || props["dormant"] == true
                        }
                        .map(&:id)
        scope = ::EventParticipant.joins(:event, :character)
                                  .where(events: { location_id: location.id })
                                  .where(characters: { location_id: location.id })
        scope = scope.where.not(characters: { id: skip_ids }) if skip_ids.any?
        scope.group("characters.name")
             .order(Arel.sql("COUNT(*) DESC"))
             .limit(RECENT_ACTORS_LIMIT)
             .count
             .map { |name, count| { "actor_name" => name, "event_count" => count } }
      end

      def recent_events_for(location)
        ::Event.where(location_id: location.id)
               .order(game_time: :desc)
               .limit(RECENT_EVENTS_LIMIT)
               .map { |ev|
                 {
                   "game_time" => ev.game_time,
                   "summary"   => ev.details["summary"] || ev.details.dig("narrative", "trigger") || ""
                 }
               }
      end
    end
  end
end
