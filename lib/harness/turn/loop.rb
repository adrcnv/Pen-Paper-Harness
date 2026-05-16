require "fileutils"
require "json"

module Harness
  module Turn
    # Skeleton of the runtime turn. One call = one player input in, one
    # narration string out. The caller (TTY, web handler, spec, REPL) loops
    # over this. The loop knows nothing about where input came from.
    #
    # Per turn:
    #   1. Build reasoning context (scene + input + recent history).
    #   2. Run the reasoning loop: LLM calls tool → resolver dispatches →
    #      result fed back to LLM → repeat until the LLM stops.
    #   3. Build narration context (outcome + scene + conversation history).
    #   4. LLM narrates.
    #   5. Persist a TurnLog transcript.
    #   6. Optionally snapshot the SQLite file.
    #   7. Rebuild the scene on the next turn if scene_dirty was set.
    #
    # The reasoning loop and the narration step are asymmetric. The reasoning
    # loop owns all state mutation, all entity creation, all queries — most
    # of the per-turn cost. The narration step is a small render: take the
    # committed outcome, write 2-4 sentences. They share "lives in the same
    # turn"; that's about it.
    class Loop
      REASONING_PREAMBLE_PATH = Rails.root.join("lib/harness/prompts/reasoning.txt")
      NARRATION_PREAMBLE_PATH = Rails.root.join("lib/harness/prompts/narration.txt")

      # Hard cap on prior narration turns handed to the reasoning loop. Loose
      # for now — tighten when we measure token usage against a real adapter.
      DEFAULT_HISTORY_CAP = 50

      # Maximum number of tool calls the reasoning loop can make per turn.
      # Guard against a misbehaving model looping forever.
      DEFAULT_MAX_TOOL_CALLS = 20

      attr_reader :logger

      def initialize(
        adapter:,
        context:,
        tools: Resolver::DEFAULT_TOOLS,
        history_cap: DEFAULT_HISTORY_CAP,
        max_tool_calls: DEFAULT_MAX_TOOL_CALLS,
        snapshot_dir: nil,
        scene_manager: nil,
        logger: Rails.logger
      )
        @adapter              = adapter
        @context              = context
        @tools                = tools
        @history_cap          = history_cap
        @max_tool_calls       = max_tool_calls
        @snapshot_dir         = snapshot_dir
        @logger               = logger
        @scene_manager        = scene_manager || ::Harness::Scene::Manager.new(context: context, logger: logger)
      end

      # Returns the Transcript for the turn (already persisted).
      def run_turn(input:)
        ::Harness::CostTracker.reset_turn!
        ::Harness::Timing.reset_turn!
        @context.reset_per_turn_counters!

        # Tools reach the LLM via context.llm_grunt (small-model, hot path
        # for materialization) or context.llm_nuance (reasoning loop).
        # If neither is set, fall back to the adapter — same .call interface
        # — and wire both tiers to it. Single-adapter setups Just Work;
        # two-tier setups configure both before run_turn.
        if @adapter.respond_to?(:call)
          @context.llm_grunt  ||= @adapter
          @context.llm_nuance ||= @adapter
        end

        # Scene lifecycle: enter on first turn (or when not yet entered),
        # exit→enter on scene_dirty (transition since last turn).
        if @context.scene_dirty && @scene_manager.active
          @scene_manager.exit
        end
        @scene_manager.ensure_entered
        @context.clear_scene_dirty!

        transcript = Transcript.new(input: input, location_id: @context.player_location.id)
        logger.info { "[Turn::Loop] input=#{input.inspect} location=#{@context.player_location.name}" }

        begin
          run_reasoning(input, transcript)

          # Combat hand-off. While scene.in_combat?, Combat::Loop processes
          # NPC slots around the player's slot. The loop YIELDS at fresh
          # player slots (end_reason: :yielded) so the next turn's reasoning
          # loop can drive the player's next combat slot. On real termination
          # (:victory / :player_died / :player_fled / :all_fled / :round_cap_reached)
          # combat ends and scene_dirty is raised by the loop.
          combat_result = nil
          if @scene_manager.active&.in_combat?
            combat_result = run_combat(transcript)
          end

          # If the reasoning loop fired a transition / travel / threshold-
          # crossing pass_time, rebuild the scene NOW — before narration —
          # so this turn's narration is recorded against the destination
          # scene's narration log. Without this, record_narration writes to
          # the OLD scene's Active, which gets wiped at next turn's start
          # (during exit), and Turn N+1's recent_history is empty even
          # though Turn N had a meaningful arrival narration. Same total
          # work as deferring the rebuild to next-turn start; just shifted
          # earlier so continuity holds across the transition.
          if @context.scene_dirty && @scene_manager.active
            @scene_manager.exit
            @scene_manager.ensure_entered
            @context.clear_scene_dirty!
          end

          # End-of-turn quest fulfillment check. Pure Ruby; no LLM. Walks
          # each active quest's current step; promotes when world state
          # satisfies the structural check. Runs BEFORE narration so the
          # narration step can render a fulfilled step as completed if
          # there's been one this turn. Idempotent — safe to fail and retry.
          ::Harness::Quests::FulfillmentCheck.run!(@context, logger: logger)

          # Pick narration source:
          # - Combat with content (rounds processed OR a player-fled wrap-up):
          #   render the combat narration.
          # - Combat yielded with NO content (bootstrap turn that fired
          #   start_combat but yielded before any NPC slot ran): fall back to
          #   the regular narration step. The player's pre-combat actions
          #   and the start_combat event are still in transcript.tool_calls
          #   and the regular narration handles them.
          # - No combat: regular narration.
          narration = if combat_result && (combat_result.round_summaries.any? || combat_result.player_fled_resolution)
            combat_narration = assemble_combat_narration(combat_result)
            transcript.narration = combat_narration
            combat_narration
          else
            run_narration(input, transcript)
          end

          @scene_manager.record_narration(input, narration)
          @context.append_turn(input: input, narration: narration)
          tick_agenda_pressure!(transcript)
          trim_history!
        rescue StandardError => e
          transcript.error = "#{e.class}: #{e.message}"
          logger.error { "[Turn::Loop] turn failed: #{transcript.error}" }
          raise
        ensure
          transcript.persist!
          snapshot_db(transcript.turn_log) if transcript.turn_log
        end

        transcript
      end

      private

      def run_reasoning(input, transcript)
        ::Harness::CostTracker.in_subsystem(:reasoning_loop) do
          resolver = Resolver.new(context: @context, tools: Resolver.tools_for(@context, normal_tools: @tools), logger: logger)
          system   = reasoning_preamble
          user     = reasoning_user_message(input)

          transcript.reasoning_prompt = user

          turn = @adapter.start_turn(system: system, user: user, tools: resolver.schemas)
          calls_made = 0

          until turn.complete?
            if calls_made >= @max_tool_calls
              logger.warn { "[Turn::Loop] reasoning loop hit max_tool_calls=#{@max_tool_calls}; aborting" }
              break
            end

            call = turn.next_tool_call
            break if call.nil?

            result = resolver.execute(call)
            transcript.record_tool_call(call, result)
            turn.feed_result(result)
            calls_made += 1
          end

          logger.info { "[Turn::Loop] reasoning done: #{calls_made} tool call(s)" }
        end
      end

      def run_narration(input, transcript)
        ::Harness::CostTracker.in_subsystem(:narration) do
          user = narration_user_message(input, transcript)
          transcript.narration_prompt = user
          narration = @adapter.complete(system: narration_preamble, user: user)
          transcript.narration = narration
          narration
        end
      end

      def run_combat(transcript)
        ::Harness::CostTracker.in_subsystem(:combat) do
          driver = ::Harness::Combat::Loop.new(context: @context, adapter: @adapter, logger: logger)
          result = driver.run
          transcript.combat = result
          logger.info { "[Turn::Loop] combat ended reason=#{result.end_reason} rounds=#{result.rounds}" }
          result
        end
      end

      def assemble_combat_narration(combat_result)
        parts = combat_result.round_summaries.map { |r| r["narration"].to_s }
        if combat_result.player_fled_resolution
          prose = combat_result.player_fled_resolution["summary_prose"].to_s
          parts << prose unless prose.empty?
        end
        parts.reject(&:empty?).join("\n\n")
      end

      def reasoning_user_message(input)
        recent = scene_history.last(@history_cap)
        player = ::Player.first
        payload = {
          "player_input"   => input,
          "player"         => { "id" => player.id, "name" => player.name },
          "location"       => { "id" => @context.player_location.id, "name" => @context.player_location.name },
          "recent_history" => recent
        }
        # Surface quests structurally relevant to the current scene. Capped
        # by visibility rule (giver present, or current step's target in/near
        # scene) so the reasoning loop isn't tempted to push unrelated
        # threads. Omitted entirely when empty.
        relevant = visible_quests_payload
        payload["relevant_quests"] = relevant if relevant.any?
        # Lead with the player identity in plain prose so it's the FIRST thing
        # the model sees, not buried in the JSON payload. Cuts wasted
        # query_character round-trips against the player's own id.
        header = "YOU ARE PLAYING: #{player.name} (character_id=#{player.id}). Use this id directly — no need to query for it.\n\n"

        "#{header}INPUT:\n#{JSON.pretty_generate(payload)}"
      end

      # Filters active + offered quests by structural-scene relevance so the
      # reasoning loop only sees what it can plausibly act on this turn.
      # Visibility rules:
      #   - offered quest with giver in present_characters → visible (the
      #     player can accept it via accept_quest).
      #   - active quest whose current step's target is in/near the scene:
      #       information / character_dead / character_at_location → target
      #         character in present_characters.
      #       item_in_inventory → target item at this location or in player's
      #         inventory.
      # All other quests stay hidden from the INPUT block (still visible via
      # /quests). Per-quest payload includes a fulfillment_hint string the
      # LLM uses as a guide for what tool calls advance the step.
      def visible_quests_payload
        active_scene = @scene_manager.active
        return [] unless active_scene
        present_char_ids = active_scene.present_characters.map(&:id).to_set
        present_loc_id   = active_scene.location.id
        player           = ::Player.first

        quests = ::Quest.where(state: %w[offered active]).includes(:quest_steps, :giver)
        out = []
        quests.each do |q|
          visible = false

          if present_char_ids.include?(q.giver_character_id)
            visible = true
          end

          if q.state == "active"
            step = q.quest_steps.where(state: "active").order(:position).first
            if step
              case step.fulfillment_kind
              when "information", "character_dead", "character_at_location"
                visible = true if step.target_character_id && present_char_ids.include?(step.target_character_id)
              when "item_in_inventory"
                item = step.target_item
                visible = true if item && (item.location_id == present_loc_id || (player && item.character_id == player.id))
              end
            end
          end

          next unless visible
          out << quest_payload(q)
        end
        out.compact
      end

      def quest_payload(quest)
        step = quest.quest_steps.where(state: "active").order(:position).first ||
               quest.quest_steps.where(state: "pending").order(:position).first
        return nil unless step
        {
          "id"          => quest.id,
          "state"       => quest.state,
          "name"        => quest.name,
          "summary"     => quest.summary,
          "archetype"   => quest.archetype_id,
          "giver"       => { "id" => quest.giver_character_id, "name" => quest.giver&.name },
          "current_step" => {
            "position"          => step.position,
            "state"             => step.state,
            "description"       => step.description,
            "fulfillment_hint"  => fulfillment_hint_for(step)
          }
        }
      end

      def fulfillment_hint_for(step)
        case step.fulfillment_kind
        when "information"
          "speak with #{step.target_character&.name || '?'} (id #{step.target_character_id}); any event tagging both you and them after this step opened satisfies it"
        when "item_in_inventory"
          "obtain item \"#{step.target_item&.name || '?'}\" (id #{step.target_item_id}); pick it up or accept it given to you"
        when "character_dead"
          "kill #{step.target_character&.name || '?'} (id #{step.target_character_id})"
        when "character_at_location"
          "#{step.target_character&.name || '?'} (id #{step.target_character_id}) must be at location \"#{step.target_location&.name || '?'}\" (id #{step.target_location_id})"
        end
      end

      def narration_user_message(input, transcript)
        payload = {
          "player_input"   => input,
          "location"       => { "id" => @context.player_location.id, "name" => @context.player_location.name, "description" => @context.player_location.description },
          "tool_calls"     => sanitize_tool_calls_for_narration(transcript.tool_calls),
          # current_scene is what's TRUE NOW. tool_calls captures what the
          # reasoning loop SAW during its turn — but the scene may have
          # rebuilt between then and now (when transition fires mid-turn,
          # the limbo fix runs Manager.exit + ensure_entered before
          # narration so the materializer populates the destination scene).
          # Any query_scene result in tool_calls captured BEFORE that
          # rebuild reflects the empty pre-materialization state. Narration
          # should trust current_scene for who/what is present; tool_calls
          # for what HAPPENED (resolve outcomes, propose_event prose, etc).
          "current_scene"  => current_scene_payload,
          "recent_history" => scene_history.last(@history_cap)
        }
        "INPUT:\n#{JSON.pretty_generate(payload)}"
      end

      def current_scene_payload
        active = @scene_manager.active
        return { "present_characters" => [], "present_items" => [], "present_corpses" => [], "present_extras" => [] } unless active
        {
          "present_characters" => active.present_characters.map { |c| { "id" => c.id, "name" => c.name, "subrole" => c.subrole } },
          "present_items"      => active.present_items.map { |i| { "id" => i.id, "name" => i.name } },
          "present_corpses"    => active.present_corpses.map { |c| { "id" => c.id, "name" => c.name } },
          "present_extras"     => active.present_extras
        }
      end

      # Strip reasoning-loop-only flavor (internal_state, agenda,
      # should_push_now) from query_scene results before forwarding to the
      # narration step. These fields are scene-entry mood snapshots intended
      # to inform the LLM's JUDGMENT — they are NOT meant to be rendered
      # verbatim in prose. Without this filter the narrator regurgitates
      # "Rask drums his axe handle" for the rest of the scene even after
      # Rask has been struck and is bleeding, because internal_state is
      # generated once at scene entry and never refreshed mid-scene.
      # Narration should render NPC state from what JUST happened (the
      # other tool results — resolve outcomes, mutate_character calls,
      # propose_event details) plus recent_history, not from the cached
      # mood line.
      NARRATION_HIDDEN_FIELDS = %w[internal_state agenda should_push_now].freeze

      def sanitize_tool_calls_for_narration(tool_calls)
        tool_calls.map { |tc|
          next tc unless tc["name"] == "query_scene"
          chars = tc.dig("result", "present_characters")
          next tc unless chars.is_a?(Array)

          stripped_chars = chars.map { |c|
            c.is_a?(Hash) ? c.reject { |k, _| NARRATION_HIDDEN_FIELDS.include?(k) } : c
          }
          new_result = tc["result"].merge("present_characters" => stripped_chars)
          tc.merge("result" => new_result)
        }
      end

      # Scene-scoped narration history. Both the reasoning loop and the
      # narration step read from this — NOT from @context.history. The
      # global @context.history persists for /history debug + session log
      # but never leaks into prompts.
      #
      # Why scene-scoped: the architectural pillar is that NPCs in a new
      # scene shouldn't have access to dialogue from a prior scene that
      # they weren't in. Theory of mind is structural — what an NPC knows
      # comes from event participation + belief materialization, never
      # from "I overheard the player tell another character" by way of
      # the LLM's conversation context. Scene transition drops the active
      # scene; the next scene starts with empty narrations.
      #
      # Cold-start cost: tonal continuity is lost across transitions. The
      # narrator comes in fresh after a scene change. If felt, mitigations
      # include passing a one-line "you just left X" hint — not built
      # today; revisit if it bites in play.
      # End-of-turn agenda pressure update. Scans this turn's tool calls for
      # NPCs who appeared as `actor` (in propose_event participants or as
      # resolve.actor_id), then ticks the active scene's agenda counters —
      # actors reset to 0, silent NPCs increment. The next turn's query_scene
      # surfaces `should_push_now: true` for any NPC whose silence crossed
      # AGENDA_PUSH_THRESHOLD. No-op if scene_dirty (the next turn rebuilds
      # the scene anyway and starts agenda counters fresh).
      def tick_agenda_pressure!(transcript)
        active = @scene_manager.active
        return unless active
        return if @context.scene_dirty
        player_id = ::Player.first&.id

        acted = transcript.tool_calls.flat_map { |tc|
          ids = []
          if (parts = tc.dig("result", "participants")).is_a?(Array)
            ids.concat(parts.select { |p| p["role"].to_s == "actor" }.map { |p| p["character_id"] })
          end
          if tc["name"] == "resolve" && (a = tc.dig("result", "actor_id"))
            ids << a
          end
          ids
        }.compact.reject { |id| id == player_id }.uniq

        active.tick_agendas!(acted)
      end

      def scene_history
        @scene_manager.active&.narrations || []
      end

      def trim_history!
        return if @context.history.size <= @history_cap
        overflow = @context.history.size - @history_cap
        @context.history.shift(overflow)
      end

      def snapshot_db(turn_log)
        return unless @snapshot_dir
        db_path = ActiveRecord::Base.connection_db_config.database
        return unless db_path && File.exist?(db_path)

        FileUtils.mkdir_p(@snapshot_dir)
        target = File.join(@snapshot_dir, "turn_#{turn_log.turn_number}.sqlite")
        FileUtils.cp(db_path, target)
        logger.debug { "[Turn::Loop] snapshot -> #{target}" }
      rescue StandardError => e
        logger.warn { "[Turn::Loop] snapshot failed: #{e.message}" }
      end

      def reasoning_preamble
        @reasoning_preamble ||= File.read(REASONING_PREAMBLE_PATH)
      end

      def narration_preamble
        @narration_preamble ||= File.read(NARRATION_PREAMBLE_PATH)
      end
    end
  end
end
