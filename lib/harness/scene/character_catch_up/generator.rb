module Harness
  module Scene
    # Character catch-up = "fill in what each present character was doing
    # off-screen during the lookback window." One batched grunt-tier call for
    # all present class-4 characters; commits 0-2 personal-scope events per
    # character; events get location=null (the character was elsewhere).
    #
    # Triggered by Scene::Manager.enter after Scene::Materializer has settled
    # the present_characters set, before InternalState runs (so internal-state
    # synthesis sees the freshly-committed character activity).
    #
    # Failure modes:
    #   - LLM unavailable        → caller skips (we never get called)
    #   - Hydrator failure       → 1 retry with parse errors as feedback, then []
    #   - ForwardAppender errors → log warning, continue with the rest
    #
    # Returns the array of committed Event rows (possibly empty).
    module CharacterCatchUp
      class Generator
        LOOKBACK_WINDOW       = 4_320  # 3 in-game days = 3 * 1440 minutes
        MAX_GENERATOR_RETRIES = 1
        RECENT_EVENTS_LIMIT   = 5

        attr_reader :logger

        def initialize(llm_client:, logger: Rails.logger, max_retries: MAX_GENERATOR_RETRIES, lookback_window: LOOKBACK_WINDOW)
          @llm             = llm_client
          @logger          = logger
          @max_retries     = max_retries
          @lookback_window = lookback_window
        end

        # characters: array of Character (class-4) rows expected to be in the
        # upcoming scene. Player rows are filtered out — we never simulate the
        # player. Characters with NO prior event history are also filtered —
        # there's no "off-screen activity" to catch up on for someone who was
        # just born; the LLM would be inventing from a vacuum and burning
        # tokens for nothing.
        def generate(characters:, current_game_time:)
          return [] unless @llm
          eligible = characters.reject { |c| c.is_a?(::Player) }
          return [] if eligible.empty?

          ids_with_history = ::EventParticipant.where(character_id: eligible.map(&:id))
                                                .distinct.pluck(:character_id).to_set
          eligible = eligible.select { |c| ids_with_history.include?(c.id) }
          return [] if eligible.empty?

          ::Harness::CostTracker.in_subsystem(:character_catch_up) do
            inputs = eligible.map { |c| character_input(c) }
            logger.info { "[Scene::CharacterCatchUp] eligible=#{eligible.size} window=#{@lookback_window}" }

            payload = call_generator(
              current_game_time: current_game_time,
              inputs:            inputs,
              valid_ids:         eligible.map(&:id)
            )
            next [] if payload.empty?

            commit(payload, eligible)
          end
        end

        private

        def character_input(c)
          {
            "character_id"        => c.id,
            "name"                => c.name,
            "subrole"             => c.subrole,
            "personality_summary" => personality_summary(c),
            "recent_events"       => recent_events_for(c)
          }
        end

        def personality_summary(c)
          props = c.properties.is_a?(Hash) ? c.properties : {}
          parts = []
          parts << props["personality"] if props["personality"].is_a?(String)
          parts << props["mood"]        if props["mood"].is_a?(String)
          parts << props["appearance_intent"] if props["appearance_intent"].is_a?(String)
          parts.compact.join("; ")
        end

        def recent_events_for(c)
          ::EventParticipant
            .where(character_id: c.id)
            .joins(:event)
            .order("events.game_time DESC, events.id DESC")
            .limit(RECENT_EVENTS_LIMIT)
            .includes(:event)
            .map { |ep|
              ev = ep.event
              {
                "game_time" => ev.game_time,
                "summary"   => ev.details["summary"] || ev.details.dig("narrative", "trigger") || ""
              }
            }
        end

        def call_generator(current_game_time:, inputs:, valid_ids:)
          prompt = Prompt.render(
            current_game_time: current_game_time,
            lookback_window:   @lookback_window,
            characters:        inputs
          )
          current_user = prompt[:user]

          attempts = 0
          loop do
            attempts += 1
            logger.debug { "[Scene::CharacterCatchUp] LLM call attempt #{attempts}" }

            raw = @llm.complete(system: prompt[:system], user: current_user)
            logger.debug { "[Scene::CharacterCatchUp] raw output (#{raw.size} bytes):\n#{raw}" }

            begin
              return Hydrator.hydrate(
                llm_output:          raw,
                current_game_time:   current_game_time,
                lookback_window:     @lookback_window,
                valid_character_ids: valid_ids
              )
            rescue Hydrator::InvalidOutput => e
              logger.warn { "[Scene::CharacterCatchUp] output invalid (attempt #{attempts}): #{e.errors.join('; ')}" }
              return [] if attempts > @max_retries
              current_user = "#{current_user}\n\nYOUR PREVIOUS OUTPUT WAS REJECTED. Errors:\n#{e.errors.map { |x| "- #{x}" }.join("\n")}\n\nFix and resubmit."
            end
          end
        end

        def commit(payload, characters)
          char_by_id = characters.index_by(&:id)
          committed  = []

          ::ActiveRecord::Base.transaction do
            payload.each do |entry|
              char = char_by_id[entry["character_id"]]
              next unless char  # extra safety beyond hydrator filter

              entry["events"].sort_by { |e| e["game_time"] }.each do |e|
                begin
                  ev = ::Harness::Event::ForwardAppender.append(
                    game_time:    e["game_time"],
                    scope:        "personal",
                    location:     nil,
                    details:      { "summary" => e["summary"], "narrative" => e["narrative"] },
                    participants: [ { character: char, role: e["role"] } ]
                  )
                  committed << ev
                rescue ::Harness::Event::ForwardAppender::InvalidEvent => err
                  logger.warn { "[Scene::CharacterCatchUp] dropped invalid event for char##{char.id} at gt=#{e['game_time']}: #{err.message}" }
                end
              end
            end
          end

          logger.info { "[Scene::CharacterCatchUp] committed=#{committed.size} across #{payload.size} characters" }
          committed
        end
      end
    end
  end
end
