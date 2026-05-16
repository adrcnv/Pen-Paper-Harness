module Harness
  module Quests
    # Top-level orchestrator. Wires archetype pick + authoring LLM call +
    # commit pass.
    #
    # Post-Phase-2:
    # - forbidden_names is gone — the LLM no longer picks character names
    #   (Naming.for assigns mechanically at commit time).
    # - local_cast now exposes character ids so the LLM can reference existing
    #   rows for the optional `reused_characters` path.
    #
    # Pipeline:
    #   1. ArchetypePicker.pick(city) → archetype hash.
    #   2. Build local_cast (id + name + subrole for all existing characters
    #      at the city + sublocations).
    #   3. Prompt.render → system + user.
    #   4. LLM call → JSON.
    #   5. Hydrator.hydrate(...) → structured payload (retries 1 with
    #      rejection feedback on shape errors).
    #   6. Committer.commit(...) → Quest row + steps + characters + locations
    #      + items + kickoff event, all in one transaction.
    class Generator
      MAX_GENERATOR_RETRIES = 1
      LOCAL_CAST_LIMIT      = 12

      attr_reader :logger

      def initialize(llm_client:, logger: ::Rails.logger, max_retries: MAX_GENERATOR_RETRIES, rng: Random.new)
        @llm         = llm_client
        @logger      = logger
        @max_retries = max_retries
        @rng         = rng
      end

      def generate(city:, current_game_time:)
        return nil unless @llm
        return nil unless top_level?(city)

        ::Harness::CostTracker.in_subsystem(:quest_generator) do
          generate_inner(city: city, current_game_time: current_game_time)
        end
      rescue ::Harness::Quests::ArchetypePicker::NoArchetypeError => e
        logger.info { "[Quest::Generator] no archetype for city=#{city.name}: #{e.message}" }
        nil
      rescue ::Harness::Quests::Committer::CommitError, ::ActiveRecord::RecordInvalid => e
        logger.warn { "[Quest::Generator] commit failed for city=#{city.name}: #{e.class}: #{e.message}" }
        nil
      rescue ::Harness::Event::BackwardAppender::Rejected, ::Harness::Event::BackwardAppender::FloorViolation => e
        logger.warn { "[Quest::Generator] kickoff event rejected for city=#{city.name}: #{e.message}" }
        nil
      end

      private

      def generate_inner(city:, current_game_time:)
        archetype = ::Harness::Quests::ArchetypePicker.pick(city: city, rng: @rng)
        logger.info { "[Quest::Generator] archetype=#{archetype['id']} for city=#{city.name}" }

        local_cast = local_cast_for(city)

        hydrated = call_authoring(
          city:              city,
          archetype:         archetype,
          current_game_time: current_game_time,
          local_cast:        local_cast
        )
        return nil if hydrated.nil?

        quest = ::Harness::Quests::Committer.commit(
          hydrated:          hydrated,
          archetype:         archetype,
          city:              city,
          current_game_time: current_game_time,
          llm_grunt:         @llm,
          rng:               @rng,
          logger:            logger
        )

        bump_generated_count!(city)
        quest
      end

      def call_authoring(city:, archetype:, current_game_time:, local_cast:)
        feedback = nil
        attempts = 0
        loop do
          attempts += 1
          prompt = Prompt.render(
            city:                city,
            archetype:           archetype,
            current_game_time:   current_game_time,
            local_cast:          local_cast,
            rejection_feedback:  feedback
          )
          raw = @llm.complete(system: prompt[:system], user: prompt[:user])
          logger.debug { "[Quest::Generator] raw output (attempt #{attempts}, #{raw.size} bytes):\n#{raw}" }

          begin
            return Hydrator.hydrate(
              llm_output:        raw,
              archetype:         archetype,
              current_game_time: current_game_time,
              local_cast:        local_cast
            )
          rescue Hydrator::InvalidOutput => e
            logger.warn { "[Quest::Generator] hydrator rejected (attempt #{attempts}): #{e.errors.join('; ')}" }
            return nil if attempts > @max_retries
            feedback = e.errors
          end
        end
      end

      def top_level?(city)
        city.parent_id.nil?
      end

      def local_cast_for(city)
        children = ::Location.where(parent_id: city.id).pluck(:id)
        location_ids = [ city.id, *children ]
        npcs = ::Npc.where(location_id: location_ids)
                    .where.not(name: nil)
                    .order(:id)
                    .limit(LOCAL_CAST_LIMIT)
                    .to_a
        return [] if npcs.empty?

        # Per-character existence floor: the earliest game_time at which the
        # character was a participant in any event. Reused characters can only
        # appear in a kickoff event at-or-after their floor (otherwise the
        # BackwardAppender's FloorViolation kills the commit). Surfacing the
        # floor here lets the LLM pick a compatible kickoff offset on the
        # first try.
        floors = ::EventParticipant.joins(:event)
                                   .where(character_id: npcs.map(&:id))
                                   .group(:character_id)
                                   .minimum("events.game_time")
        npcs.map { |c|
          {
            "id"                         => c.id,
            "name"                        => c.name,
            "subrole"                     => c.subrole,
            "earliest_event_game_time"    => floors[c.id]  # nil if no events
          }
        }
      end

      def bump_generated_count!(city)
        props = (city.properties || {}).dup
        count = props["quest_generated_count"].to_i + 1
        props["quest_generated_count"] = count
        city.update!(properties: props)
      end
    end
  end
end
