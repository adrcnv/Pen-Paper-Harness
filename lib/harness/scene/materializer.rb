module Harness
  module Scene
    # Fills a sublocation with characters, via two mechanisms (post-Phase-2):
    #
    # 1. Wake — a DORMANT historical from Genesis (a named figure with rich
    #    event history who hasn't surfaced in play yet) gets woken into this
    #    scene: properties.dormant cleared, relocated, subrole assigned. The
    #    founder Korr, named in a backstory event but never seen, walks out
    #    of the tavern's back room.
    # 2. Spawn — fresh Character rows invented from the sublocation's
    #    description and subrole hint, to fill any remaining slots.
    #
    # The reuse pool is dormant-ONLY by design. ACTIVE residents are never
    # relocated by the Materializer — that permanently teleports a character
    # the player may have just met AND rewrites their subrole (the dock
    # worker who "followed me to the tavern and became a barkeep" bug).
    # Bringing an active resident into a scene is the job of the TRANSIENT
    # draws (Scene::LocalDraw intra-city, Scene::TravelerPull cross-city):
    # they borrow a row (current ← here, home untouched, subrole preserved)
    # and Scene::Evictor sends them home on exit. The Materializer only
    # introduces characters who are NEW to play — woken dormants and fresh
    # spawns — both of which legitimately settle here.
    #
    # Class-2 promotion was a third channel; retired with Phase 2. Genesis
    # eager-spawns dormant rows for every named historical, so anyone who
    # could plausibly be woken already has a row.
    #
    # Preference order: wake-dormant > spawn. The LLM judges both in a
    # single call.
    class Materializer
      attr_reader :logger

      def initialize(llm_client:, logger: Rails.logger, max_retries: 2)
        @llm         = llm_client
        @logger      = logger
        @max_retries = max_retries
      end

      def materialize(location:, target_count:)
        already        = present_already(location)
        candidate_ids  = candidate_pool_location_ids(location)
        slots_to_fill  = target_count - already.size

        logger.info { "[Scene::Materializer] location=#{location.name} target=#{target_count} present=#{already.size} slots=#{slots_to_fill}" }

        if slots_to_fill <= 0
          return { reused: [], spawned: [] }
        end

        ::Harness::CostTracker.in_subsystem(:scene_materializer) do
          cands = candidates(candidate_ids, already)
          entries = call_with_retries(
            location:         location,
            parent:           location.parent,
            already:          already,
            candidates:       cands,
            target_count:     target_count,
            slots_to_fill:    slots_to_fill
          )

          apply(location, entries)
        end
      end

      private

      # NPCs already at THIS location, including dormant — present_already
      # is the "don't duplicate me" set for the LLM. Dormant rows still
      # count toward the present total when the materializer is filling
      # slots; they exist structurally and the materializer can pick them
      # as "reuse-with-wake" rather than spawning a duplicate name.
      def present_already(location)
        ::Npc.where(location_id: location.id).to_a
      end

      # Wake candidate pool: characters living at this sublocation's parent
      # city OR any sibling sublocation. The `candidates` filter narrows this
      # to dormant historicals only (active residents are handled by the
      # transient draws, not the Materializer).
      def candidate_pool_location_ids(location)
        if location.parent_id
          [ location.parent_id ] + ::Location.where(parent_id: location.parent_id).pluck(:id)
        else
          [ location.id ]
        end
      end

      # DORMANT historicals in the candidate pool, excluding those already at
      # THIS sublocation. Active residents are deliberately excluded — the
      # Materializer only ever introduces characters new to play (woken
      # dormants + fresh spawns); active residents reach a scene via the
      # transient draws (LocalDraw / TravelerPull), which preserve identity
      # and send them home on exit. Each candidate carries character_id,
      # name, current subrole, and a thin event-history slice for LLM
      # judgment (is this founder plausibly still alive and around?).
      def candidates(candidate_location_ids, already_present)
        already_ids = already_present.map(&:id)
        ::Npc.where(location_id: candidate_location_ids)
             .where.not(id: already_ids)
             .select { |c| dormant?(c) }
             .map { |c|
               {
                 character_id: c.id,
                 name:         c.name,
                 subrole:      c.subrole,
                 dormant:      true,
                 history:      history_for(c)
               }
             }
      end

      def dormant?(character)
        props = character.properties
        props.is_a?(Hash) && props["dormant"] == true
      end

      def history_for(character, limit: 5)
        ::EventParticipant
          .joins(:event)
          .where(character_id: character.id)
          .order("events.game_time DESC, events.id DESC")
          .limit(limit)
          .includes(:event)
          .map { |ep| summarize(ep) }
      end

      def summarize(participant)
        ev = participant.event
        {
          "game_time" => ev.game_time,
          "scope"     => ev.scope,
          "role"      => participant.role,
          "details"   => ev.details
        }
      end

      def apply(location, entries)
        reused  = []
        spawned = []

        ::Npc.transaction do
          entries["reuse"].each do |e|
            char  = ::Npc.find(e["character_id"])
            attrs = { location_id: location.id }
            attrs[:subrole] = e["subrole"] if e["subrole"]
            # Wake-on-reuse: clear properties.dormant if set. The
            # LLM-provided properties merge on top, so callers may also
            # override anything else in properties (mood, disposition).
            base_props = char.properties.is_a?(Hash) ? char.properties.dup : {}
            base_props.delete("dormant") if base_props["dormant"] == true
            base_props.merge!(e["properties"]) if e["properties"].is_a?(Hash) && e["properties"].any?
            attrs[:properties] = base_props if base_props.any? || char.properties.is_a?(Hash) && char.properties["dormant"]
            was_dormant = dormant?(char)
            char.update!(attrs)
            logger.info { "[Scene::Materializer] #{was_dormant ? 'woke dormant' : 'reused'} #{char.name} -> #{location.name}" } if was_dormant
            reused << char
          end

          entries["spawn"].each do |e|
            props = e["properties"].is_a?(Hash) ? e["properties"] : {}
            # Mechanical name from the kingdom's culture. unique_for avoids
            # collisions against existing rows; falls back to a Roman-numeral
            # suffix in the rare exhausted-pool case.
            mech_name = ::Harness::Naming.unique_for(location: location)
            ctx_parts = []
            ctx_parts << "Spawned at #{location.name} (#{location.description.to_s.slice(0, 200)})" if location.description.present?
            ctx_parts << "Subrole: #{e['subrole']}" if e["subrole"]
            ctx_parts << "Properties: #{props.to_json}" if props.any?
            spawned << ::Harness::Character::Hatchery.spawn(
              llm_grunt:     @llm,
              name:          mech_name,
              subrole:       e["subrole"],
              location_id:   location.id,
              # Residents (settlement dwellers, lair occupants like bandits/
              # hermits) live where they're spawned; NPCs filling a social
              # waypoint / open wild stay homeless (evicted/culled on exit).
              home_location_id: (location.residence? ? location.id : nil),
              properties:    props,
              prose_context: ctx_parts.any? ? ctx_parts.join("\n") : nil
            )
          end
        end

        logger.info { "[Scene::Materializer] reused=#{reused.size} spawned=#{spawned.size}" }
        { reused: reused, spawned: spawned }
      end

      def call_with_retries(location:, parent:, already:, candidates:, target_count:, slots_to_fill:)
        attempts = 0
        prompt = Prompt.render(
          location:        location,
          parent:          parent,
          already_present: already,
          candidates:      candidates,
          target_count:    target_count,
          slots_to_fill:   slots_to_fill
        )
        candidate_ids = candidates.map { |c| c[:character_id] }
        present_names = already.map(&:name)
        current_user  = prompt[:user]

        loop do
          attempts += 1
          logger.debug { "[Scene::Materializer] LLM call attempt #{attempts}" }

          raw = @llm.complete(system: prompt[:system], user: current_user)
          logger.debug { "[Scene::Materializer] raw output (attempt #{attempts}, #{raw.size} bytes):\n#{raw}" }

          begin
            return Hydrator.hydrate(
              llm_output:    raw,
              candidate_ids: candidate_ids,
              present_names: present_names,
              slots_to_fill: slots_to_fill
            )
          rescue Hydrator::InvalidOutput => e
            logger.warn { "[Scene::Materializer] validation failed (attempt #{attempts}/#{@max_retries + 1}): #{e.errors.join('; ')}" }
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
