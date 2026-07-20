module Harness
  module Genesis
    # Genesis = "make this top-level location feel like it already had a past."
    # Two invocation sites:
    #   1. propose_location wilderness_leaf — runtime player-driven creation.
    #   2. Scene::Manager.enter — first scene entry to a worldgen-rooted city
    #      that has zero events (the deferred half of two-pass worldgen
    #      seeding from CLAUDE.md).
    # Two LLM calls per attempt (cluster generator + BackwardAppender's
    # internal validator) plus a logical-retry on rejection. The Generator
    # itself is type-agnostic; callers gate when to invoke it.
    #
    # Pipeline:
    #   1. Generator LLM call → cluster of 0-8 past events with named
    #      participants (string names in the JSON output).
    #   2. Eager-Hatchery every named participant into a class-4 Character
    #      row with properties.dormant = true. Dormant rows exist
    #      structurally (so event_participants can FK to them) but stay
    #      out of present_characters / recent_actors until Scene::Materializer
    #      wakes them at scene entry. This is the "force participants to
    #      spawn in the world" axis — the player can find and interact
    #      with any historical figure named in genesis events, just by
    #      walking into the right location.
    #   3. BackwardAppender.append(events: cluster, ...) → validates internal
    #      consistency + against the after-set, commits if accepted, raises
    #      Rejected with reasons if not.
    #   4. On Rejected, retry generator with reasons as feedback (1 retry).
    #
    # Cost: one Hatchery call per unique participant. A 2-event cluster
    # with 3 named participants = 3 Hatchery calls (each is a stats +
    # description + abilities materialization). Acceptable as a one-time
    # genesis cost per location; the rows persist forever.
    #
    # Failure handling:
    #   - LLM unavailable      → caller skips genesis (we never get called)
    #   - Generator hydrator   → retries 1 time with the parse errors
    #   - Validator hydrator   → handled inside BackwardAppender (1 repair retry)
    #   - Validator rejection  → retries generator 1 time with reasons
    #   - Repeated rejection   → returns []; caller logs warning and moves on
    #
    # Returns the array of committed Event rows (possibly empty).
    class Generator
      MAX_GENERATOR_RETRIES = 1
      SCENARIO_TABLE = "genesis"

      attr_reader :logger

      def initialize(llm_client:, logger: Rails.logger, max_retries: MAX_GENERATOR_RETRIES, rng: Random.new)
        @llm         = llm_client
        @logger      = logger
        @max_retries = max_retries
        @rng         = rng
      end

      def generate(location:, anchor:, current_game_time:, connection: nil)
        return [] unless @llm

        ::Harness::CostTracker.in_subsystem(:genesis) do
          generate_inner(location: location, anchor: anchor, current_game_time: current_game_time, connection: connection)
        end
      end

      private

      def generate_inner(location:, anchor:, current_game_time:, connection:)
        scenario = ::Harness::Scenarios::Roller.roll(
          table:   SCENARIO_TABLE,
          context: { biome: location.biome },
          rng:     @rng
        )
        logger.info { "[Genesis::Generator] scenario rolled for #{location.name}: #{scenario.id}" }

        attempts = 0
        feedback = nil
        loop do
          attempts += 1
          logger.info { "[Genesis::Generator] attempt #{attempts} for #{location.name}" }

          hydrated = call_generator(
            location:          location,
            anchor:            anchor,
            current_game_time: current_game_time,
            connection:        connection,
            scenario_seed:     scenario.prompt_seed,
            feedback:          feedback
          )

          characters_payload = hydrated.characters
          events_payload     = hydrated.events

          if events_payload.empty?
            logger.info { "[Genesis::Generator] generator returned 0 events for #{location.name}; nothing to commit" }
            return []
          end

          result = nil
          begin
            # Eager-Hatchery one Character row per `characters[]` entry, with
            # a mechanical name from the kingdom's culture. Wrapped in an
            # outer transaction so a BackwardAppender rejection rolls back
            # any character rows created.
            ::ActiveRecord::Base.transaction do
              character_by_actor_id = materialize_characters(characters_payload, events_payload, location)
              bake_names!(events_payload, character_by_actor_id)
              event_kwargs          = events_payload.map { |e| to_event_kwargs(e, location, character_by_actor_id) }
              result = ::Harness::Event::BackwardAppender.append(
                events:     event_kwargs,
                llm_client: @llm,
                logger:     logger
              )
            end
            mirror_into_knowledge(result.events, location, current_game_time)
            return result.events
          rescue ::Harness::Event::BackwardAppender::Rejected => e
            logger.warn { "[Genesis::Generator] cluster rejected for #{location.name}: #{e.reasons.join('; ')}" }

            if attempts > @max_retries
              logger.warn { "[Genesis::Generator] giving up after #{attempts} attempts; no genesis events committed for #{location.name}" }
              return []
            end

            feedback = e.reasons
          end
        end
      end

      private

      def call_generator(location:, anchor:, current_game_time:, connection:, scenario_seed:, feedback:)
        prompt = Prompt.render(
          location_name:     location.name,
          description:       location.description,
          biome:             location.biome,
          # Mechanical economic identity (terrain/basis/size/wealth). Without it
          # genesis grounds history on biome + free-text alone — which is how a
          # SALT hamlet got a HARBOR-founding event. Same facts query_scene uses.
          setting:           ::Harness::Settlement::Facts.presentable(location),
          anchor_name:       anchor&.name,
          anchor_biome:      anchor&.biome,
          current_game_time: current_game_time,
          connection:        connection,
          regional_context:  regional_context_for(anchor),
          scenario_seed:     scenario_seed,
          rejection_feedback: feedback
        )
        current_user = prompt[:user]

        attempts = 0
        loop do
          attempts += 1
          logger.debug { "[Genesis::Generator] generator LLM call attempt #{attempts}" }

          raw = @llm.complete(system: prompt[:system], user: current_user)
          logger.debug { "[Genesis::Generator] raw output (attempt #{attempts}, #{raw.size} bytes):\n#{raw}" }

          begin
            return Hydrator.hydrate(llm_output: raw, current_game_time: current_game_time)
          rescue Hydrator::InvalidOutput => e
            logger.warn { "[Genesis::Generator] generator output invalid (attempt #{attempts}): #{e.errors.join('; ')}" }
            return Hydrator::Result.new(characters: [], events: []) if attempts > 1
            current_user = "#{current_user}\n\nYOUR PREVIOUS OUTPUT WAS REJECTED:\n#{e.errors.map { |x| "- #{x}" }.join("\n")}\n\nFix and resubmit."
          end
        end
      end

      # GENESIS→KNOWLEDGE MIRROR: founding history is standing communal lore —
      # the rare instance where an actual event is knowledge too. The event
      # rows stay participation-gated (their dormant participants recall
      # them); the town at large knows the STORY via knowledge rows anchored
      # at the location (Query's up-chain serves every sublocation), which
      # closes the founding-history-invisible-to-everyone hole without
      # widening the event gate. game_time is the capture stamp (knowledge is
      # never temporal). Non-fatal — the events stand alone if this fails.
      def mirror_into_knowledge(events, location, current_game_time)
        mirrored = events.count do |ev|
          content = ev.details.is_a?(::Hash) ? ev.details["summary"].to_s.strip : ""
          next false if content.empty?
          ::Knowledge.create!(
            content:     content,
            location_id: location.id,
            current:     true,
            source_kind: "genesis",
            game_time:   current_game_time
          )
          true
        end
        logger.info { "[Genesis::Generator] mirrored #{mirrored}/#{events.size} genesis event(s) into town knowledge for #{location.name}" }
      rescue StandardError => e
        logger.warn { "[Genesis::Generator] knowledge mirror failed (events stand alone): #{e.class}: #{e.message}" }
      end

      # Surface a thin slice of regional+ events as flavor context (NOT the
      # validator's after-set — that's BackwardAppender's job). Capped to the
      # tail; this is for the generator's prompt budget, not for correctness.
      REGIONAL_CONTEXT_LIMIT = 30
      def regional_context_for(anchor)
        return [] unless anchor
        ::Event.where(scope: %w[regional kingdom world])
               .order(game_time: :asc)
               .last(REGIONAL_CONTEXT_LIMIT)
               .map { |ev|
                 {
                   "id"        => ev.id,
                   "game_time" => ev.game_time,
                   "scope"     => ev.scope,
                   "summary"   => ev.details["summary"] || ev.details["narrative"]&.slice(0, 120) || ""
                 }
               }
      end

      # Materialize a class-4 Character row for EVERY entry in `characters[]`.
      # The LLM declared {id, subrole}; the engine assigns a mechanical name
      # (Harness::Naming.unique_for against the kingdom culture) and Hatcheries
      # the row dormant so it exists structurally but stays out of
      # present_characters / recent_actors until Scene::Materializer wakes it.
      #
      # Returns a `character_by_actor_id` map: the LLM's cluster-local id →
      # the Character row. Event participants resolve through this map at
      # commit time.
      #
      # Per-character prose context (the cluster's narratives referencing
      # them via actor_id) flows into the stat materializer so a "founder
      # named in a tragic founding event" gets stats that fit.
      def materialize_characters(characters_payload, events_payload, location)
        out = {}
        characters_payload.each do |c|
          actor_id = c["id"]
          subrole  = c["subrole"]
          mech_name = ::Harness::Naming.unique_for(location: location, rng: @rng)
          out[actor_id] = ::Harness::Character::Hatchery.spawn(
            llm_grunt:     @llm,
            name:          mech_name,
            subrole:       subrole,
            location_id:   location.id,
            # Genesis historicals are residents of the city they anchor.
            home_location_id: (location.residence? ? location.id : nil),
            dormant:       true,
            rng:           @rng,
            prose_context: prose_context_for(actor_id, events_payload)
          )
        end
        out
      end

      # Bake minted names into the cluster's prose BEFORE commit. The LLM
      # writes actor-id slugs ("the storm_captain guided…"); participants get
      # real rows but the slugs stayed in summary/narrative text, making the
      # lore unattributable downstream — no consumer could connect
      # "storm_captain" to the minted row, so speakers invented names and the
      # realizer minted duplicates (the Kaelen cascade). "the <slug>" collapses
      # to the bare name so the article doesn't strand ("The storm_captain
      # guided" → "Aelorin Greymantle guided"). The knowledge mirror runs
      # after commit and inherits the fix.
      def bake_names!(events_payload, character_by_actor_id)
        events_payload.each do |e|
          details = e["details"]
          next unless details.is_a?(::Hash)
          %w[summary narrative].each do |key|
            text = details[key]
            next unless text.is_a?(String)
            character_by_actor_id.each do |actor_id, char|
              slug = actor_id.to_s.strip
              next if slug.empty? || char.nil?
              text = text.gsub(/\b[Tt]he\s+#{Regexp.escape(slug)}\b/, char.name)
                         .gsub(/\b#{Regexp.escape(slug)}\b/, char.name)
            end
            details[key] = text
          end
        end
      end

      def prose_context_for(actor_id, events_payload)
        narratives = events_payload.select { |e|
          Array(e["participants"]).any? { |p| p["actor_id"].to_s.strip == actor_id }
        }.map { |e|
          summary = e.dig("details", "summary").to_s
          narrative = e.dig("details", "narrative").to_s
          [ summary, narrative ].reject(&:empty?).join(" — ")
        }.reject(&:empty?)
        return nil if narratives.empty?
        narratives.join("\n")
      end

      # Hydrator output (string-keyed) → BackwardAppender keyword args
      # (symbol-keyed, with location object). Every participant is a
      # class-4 :character row — class-2 strings are retired post-Phase-2.
      # materialize_characters guarantees character_by_actor_id covers
      # every actor_id referenced by the events array.
      def to_event_kwargs(event_payload, location, character_by_actor_id)
        {
          game_time:    event_payload["game_time"],
          scope:        event_payload["scope"],
          location:     location,
          details:      event_payload["details"],
          participants: event_payload["participants"].map { |p|
            aid  = p["actor_id"]
            char = character_by_actor_id.fetch(aid) {
              raise "BUG: participant actor_id=#{aid.inspect} not materialized into character_by_actor_id; this should be impossible"
            }
            { character: char, role: p["role"] }
          }
        }
      end
    end
  end
end
