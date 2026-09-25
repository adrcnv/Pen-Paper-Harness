module Harness
  module Scene
    # Generates per-character internal-state prose AND ambient extras for a
    # scene in a single LLM call. Pure flavor — keeps NPCs from feeling
    # like question-answering automata, and paints the room's non-human
    # life (a dog, gulls, smoke) for perception to mention. Conditioned on
    # each character's subrole, properties, and recent events.
    #
    # Single batched LLM call per scene (one prompt, internal_states +
    # extras both in output). Small-model tier. Cached on Scene::Active and
    # discarded at scene exit. Extras are RAM-only — no DB row, never a
    # person, never a speaker or a target (ruling 2026-09-25).
    #
    # Player rows are excluded — internal state is for NPCs.
    class InternalState
      # agendas is {character_id => agenda_text}, seeded per present character
      # (their angle toward the player this scene). Some characters have none.
      # The post-narration initiative consumer reads these to decide who acts.
      Result = Struct.new(:internal_state, :agendas, :extras, :doing, keyword_init: true)

      attr_reader :logger

      def initialize(llm_client:, logger: Rails.logger, max_retries: 2)
        @llm         = llm_client
        @logger      = logger
        @max_retries = max_retries
      end

      # Returns Result(internal_state: {char_id => prose}, agendas: {char_id => text}, extras: [str, ...]).
      def generate(location:, characters:)
        npcs = characters.select { |c| c.is_a?(::Npc) }

        # Empty-NPCs case is NOT a skip: the prompt produces extras-only
        # output (the place's ambient life) so narration has scene flavor to
        # render. Genuinely empty places (a private study) get back an empty
        # extras list via the prompt's own judgment.
        ::Harness::CostTracker.in_subsystem(:scene_internal_state) do
          generate_inner(location, npcs)
        end
      end

      private

      def generate_inner(location, npcs)
        names = npcs.map(&:name)
        by_name = npcs.each_with_object({}) { |n, h| h[n.name] = n }

        hydrated = call_with_retries(
          location:       location,
          characters:     npcs,
          expected_names: names
        )

        state_by_id = hydrated.internal_states.each_with_object({}) do |(name, prose), out|
          npc = by_name[name]
          next unless npc  # hydrator already enforced this; defensive
          out[npc.id] = prose
        end

        agendas_by_id = hydrated.agendas.each_with_object({}) do |(name, text), out|
          npc = by_name[name]
          out[npc.id] = text if npc
        end

        doing_by_id = Array(hydrated.doing).each_with_object({}) do |(name, text), out|
          npc = by_name[name]
          out[npc.id] = text if npc
        end

        # Evidence for the initiative pass: how many of the present NPCs got an
        # agenda (empty agendas = nothing for Scene::Initiative to act on, the
        # "no agenda felt" failure). INFO so it shows without --log-level=debug;
        # the full text at DEBUG.
        logger.info { "[Scene::InternalState] agendas #{agendas_by_id.size}/#{npcs.size} present at #{location.name}: #{agendas_by_id.empty? ? '(none)' : hydrated.agendas.keys.join(', ')}" }
        logger.debug { "[Scene::InternalState] agenda text: #{hydrated.agendas.inspect}" }

        Result.new(internal_state: state_by_id, agendas: agendas_by_id, extras: hydrated.extras, doing: doing_by_id)
      end

      private

      def call_with_retries(location:, characters:, expected_names:)
        attempts = 0
        prompt   = Prompt.render(location: location, characters: characters)
        current_user = prompt[:user]

        loop do
          attempts += 1
          logger.debug { "[Scene::InternalState] LLM call attempt #{attempts}" }

          raw = @llm.complete(system: prompt[:system], user: current_user)
          logger.debug { "[Scene::InternalState] raw output (attempt #{attempts}, #{raw.size} bytes):\n#{raw}" }

          begin
            return Hydrator.hydrate(llm_output: raw, expected_names: expected_names)
          rescue Hydrator::InvalidOutput => e
            logger.warn { "[Scene::InternalState] validation failed (attempt #{attempts}/#{@max_retries + 1}): #{e.errors.join('; ')}" }
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
