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

      # How many times a single turn may re-dispatch when a runner reports its
      # plan went stale under the world (:redispatch). On exhaustion the turn
      # HARD-STOPS and logs `unresolved:` — the loud dead-end (locked decision
      # #3), and the guard against re-dispatch becoming its own runaway (#6).
      REDISPATCH_CAP = 2

      # Turn execution mode.
      #   :state_machine — dispatcher → ordered plan → chained runners (default).
      #   :agentic       — the legacy single big tool-use loop, FROZEN. Kept as
      #                    a dev/escape toggle, NOT a routing fallback. Tuning
      #                    goes to the state machine.
      # Resolved from arg > ENV[HARNESS_MODE] > :state_machine.
      def self.resolve_mode(arg)
        (arg || ENV["HARNESS_MODE"] || "state_machine").to_s.strip.downcase.to_sym
      end

      attr_reader :logger, :mode

      def initialize(
        adapter:,
        context:,
        tools: Resolver::DEFAULT_TOOLS,
        history_cap: DEFAULT_HISTORY_CAP,
        max_tool_calls: DEFAULT_MAX_TOOL_CALLS,
        snapshot_dir: nil,
        scene_manager: nil,
        mode: nil,
        registry: nil,
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
        @mode                 = self.class.resolve_mode(mode)

        # Runner registry. Only built runners live here; unbuilt plan labels
        # route the whole turn agentically (build-time scaffold, see
        # Dispatcher#built?). Grows as runners land (movement, conversation, …).
        # Injectable for tests.
        @registry = registry || {
          "inspection"   => ::Harness::Runners::Inspection.new(logger: logger),
          "movement"     => ::Harness::Runners::Movement.new(logger: logger),
          "conversation" => ::Harness::Runners::Conversation.new(logger: logger),
          "worldbuilding" => ::Harness::Runners::Worldbuilding.new(logger: logger),
          # No "dice" runner — a roll is a mechanism INSIDE an interaction, not
          # its own step. The planner must never emit a standalone dice step;
          # each runner rolls when its own action is contested (conversation →
          # persuasion, environment → climb/force/lockpick, inventory → loot a
          # container). Movement NEVER rolls. A stray "dice" label from the
          # planner is remapped to environment by the Dispatcher.
          "environment"  => ::Harness::Runners::Environment.new(logger: logger),
          "inventory"    => ::Harness::Runners::Inventory.new(logger: logger),
          "time-skip"    => ::Harness::Runners::TimeSkip.new(logger: logger),
          "combat"       => ::Harness::Runners::Combat.new(logger: logger),
          "meta"         => ::Harness::Runners::Meta.new(logger: logger)
        }
        @dispatcher = ::Harness::Dispatcher.new(
          context: context, scene_manager: @scene_manager, registry: @registry, logger: logger
        )
        logger.info { "[Turn::Loop] mode=#{@mode} runners=[#{@registry.keys.join(', ')}]" }
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

        # Shadow-mode planner (diagnostic; OFF unless HARNESS_SHADOW_PLANNER).
        # Runs BEFORE the live reasoning loop so it sees the same pre-turn
        # scene the agentic loop sees. Executes nothing — just captures a plan
        # we log alongside what the agentic loop actually does. Fully
        # failure-isolated; never affects the live turn.
        shadow_result = maybe_run_shadow_planner(input)

        begin
          if @mode == :agentic
            run_reasoning(input, transcript)
          elsif @scene_manager.active&.in_combat?
            # Already mid-fight: the player's input IS their combat slot. Skip
            # the dispatcher and drive the slot via the combat-mode tool
            # surface (Resolver.tools_for swaps to COMBAT_TOOLS when
            # in_combat?). Combat is a sub-mode; the round-driver hand-off
            # below runs the NPC slots. Without this guard the dispatcher would
            # route to the combat ENTRY runner, which calls start_combat, gets
            # "already in combat", and re-dispatches to the cap — losing the
            # player's action. The combat runner ENTERS a fight; this CONTINUES
            # one.
            logger.debug { "[Turn::Loop] already in combat → combat-mode slot (dispatcher skipped)" }
            run_reasoning(input, transcript)
          else
            run_state_machine(input, transcript)
          end

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
          # Gated by HARNESS_QUESTS=on (see lib/harness/quests.rb).
          ::Harness::Quests::FulfillmentCheck.run!(@context, logger: logger) if ::Harness::Quests.enabled?

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

          # Character initiative — runs AFTER narration on purpose, so the
          # consumer reads what just happened and appends ONE present NPC's
          # unprompted move as its own foregrounded trailing beat (the system
          # supplying the engagement the LLM never volunteers). Skipped during
          # combat (it owns its own beats) and when the player is leaving the
          # scene (the agenda belongs to the scene being left).
          unless combat_result || @context.scene_dirty || @scene_manager.active&.in_combat?
            beat = maybe_run_initiative(transcript, narration)
            if beat && !beat.empty?
              narration = "#{narration}\n\n#{beat}"
              transcript.narration = narration
            end
          end

          # Record only the diegetic narration to scene history (keeps the
          # fiction record clean). The OOC notice below is display-only.
          @scene_manager.record_narration(input, narration)
          @context.append_turn(input: input, narration: narration)
          transcript.notice = unresolved_notice(transcript.unresolved) if transcript.unresolved
          trim_history!
        rescue StandardError => e
          transcript.error = "#{e.class}: #{e.message}"
          logger.error { "[Turn::Loop] turn failed: #{transcript.error}" }
          raise
        ensure
          transcript.persist!
          snapshot_db(transcript.turn_log) if transcript.turn_log
          maybe_log_shadow_planner(shadow_result, transcript)
        end

        transcript
      end

      private

      # A justified fourth-wall break: when a turn dead-ends, tell the PLAYER
      # (out of character) what the engine couldn't do, so they can rephrase.
      # This is distinct from the diegetic non-event narration — that keeps the
      # fiction intact ("the way isn't clear"); this names the engine limit.
      def unresolved_notice(reason)
        r = reason.to_s.strip
        r = "that action couldn't be carried out" if r.empty?
        "( ⚙ Out of character — the engine couldn't resolve: #{r}. Try rephrasing or being more specific. )"
      end

      # Run the shadow planner if enabled. Returns the planner result hash, or
      # nil (disabled, or any failure — the diagnostic must never break play).
      #
      # Only meaningful in :agentic mode: it logs what the planner WOULD do
      # next to what the agentic loop actually did. In :state_machine mode the
      # dispatcher already plans live (and logs to play.log), so a second
      # shadow plan is a redundant extra LLM call — skip it even if the flag is
      # still set from an earlier diagnostic session.
      def maybe_run_shadow_planner(input)
        return nil unless ::Harness::Shadow.enabled?
        if @mode != :agentic
          logger.debug { "[Turn::Loop] shadow planner skipped (redundant in #{@mode} mode; dispatcher plans live)" }
          return nil
        end
        ::Harness::Shadow::Planner.run(
          context:       @context,
          scene_manager: @scene_manager,
          input:         input,
          logger:        logger
        )
      rescue StandardError => e
        logger.warn { "[Turn::Loop] shadow planner failed: #{e.class}: #{e.message}" }
        nil
      end

      # Append the planner plan + the agentic actual to the JSONL sink. No-op
      # when the planner didn't run. Failure-isolated.
      def maybe_log_shadow_planner(shadow_result, transcript)
        return unless shadow_result
        record = ::Harness::Shadow::Log.record_for(
          turn_number:    transcript.turn_log&.turn_number,
          planner_result: shadow_result,
          transcript:     transcript
        )
        ::Harness::Shadow::Log.append(record, logger: logger)
      rescue StandardError => e
        logger.warn { "[Turn::Loop] shadow log failed: #{e.class}: #{e.message}" }
      end

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

      # State-machine turn: dispatch → ordered plan → chained runners.
      # Two whole-turn escapes to the agentic loop, both LOUD in the log and
      # NEITHER a per-step fallback:
      #   - dispatcher produced no usable plan (the planner itself failed),
      #   - the plan names a runner we haven't built yet (build-time scaffold).
      # Once all runners exist, only an explicit :agentic mode reaches the loop.
      def run_state_machine(input, transcript)
        plan = @dispatcher.plan(input)

        if plan.failed? || plan.empty?
          logger.info { "[Executor] no usable plan (#{plan.failed? ? 'parse-fail' : 'empty'}) → agentic this turn" }
          return run_reasoning(input, transcript)
        end

        unbuilt = plan.steps.map(&:runner).reject { |r| @dispatcher.built?(r) }.uniq
        if unbuilt.any?
          logger.info { "[Executor] plan needs unbuilt runner(s) #{unbuilt.inspect} → agentic this turn (scaffold)" }
          return run_reasoning(input, transcript)
        end

        execute_chain(plan.steps, input, transcript)
      end

      # Run an ordered list of Dispatcher::Step through their runners. Handoff
      # between steps is the WORLD (each step re-assembles the live scene), not
      # text — no summarization. Chain control:
      #   :combat     — hard terminator; abort remaining steps (turn loop's
      #                 combat hand-off takes over).
      #   :redispatch — plan went stale under the world; re-plan the remainder,
      #                 bounded by REDISPATCH_CAP, then hard-stop (`unresolved:`).
      #   scene_dirty — re-enter the scene before the next step runs (the
      #                 trailing one is left to the pre-narration rebuild).
      def execute_chain(steps, input, transcript)
        pending      = steps.dup
        redispatches = 0
        step_no      = 0
        # Locations created EARLIER in this chain (by a worldbuilding step). The
        # create-then-enter handoff: worldbuilding gives the new place an
        # invented NAME ("The Blackwood"), but the player asked for a generic
        # word ("forest"), so a movement step that re-searches by the player's
        # word can never find it (→ redispatch loop → duplicate places, player
        # never moves). The world IS the handoff, but the movement runner can't
        # IDENTIFY which row the chain just made — so the executor hands it the
        # pointer. This is chain orchestration (the executor's job), not a runner
        # forking to a sibling: movement just receives a resolved destination,
        # same category as a planner arg.
        chain_created_locations = []
        logger.debug { "[Executor] chain start: #{steps.size} step(s) [#{steps.map(&:runner).join(' → ')}]" }

        until pending.empty?
          step = pending.shift
          step_no += 1
          runner = @dispatcher.runner_for(step.runner)
          unless runner
            logger.warn { "[Executor] step #{step_no}: no runner for #{step.runner.inspect} → unresolved: #{step.intent}" }
            transcript.unresolved = step.intent
            break
          end

          scene = ::Harness::Tools::QueryScene.build(@context)
          logger.debug { "[Executor] step #{step_no}/#{step_no + pending.size}: #{step.runner} — #{step.intent}" }

          # Hand a movement step the location an earlier worldbuilding step made.
          if step.runner == "movement" && (made = chain_created_locations.last)
            step.args = (step.args || {}).merge("_resolved_destination" => made)
          end

          outcome = runner.run(context: @context, scene: scene, input: input, step: step)
          transcript.record_tool_calls(outcome.tool_calls)
          outcome.tool_calls.each do |tc|
            next unless tc["name"] == "propose_location"
            r = tc["result"]
            chain_created_locations << { "id" => r["location_id"], "type" => r["type"], "name" => r["name"] } if r.is_a?(Hash) && r["location_id"]
          end
          logger.info { "[Executor] step #{step_no} #{step.runner} → #{outcome.status} (#{outcome.tool_calls.size} tool call(s))#{outcome.note ? " #{outcome.note}" : ''}" }

          if outcome.combat?
            logger.info { "[Executor] combat terminator at step #{step_no}; aborting #{pending.size} remaining step(s)" }
            break
          end

          if outcome.redispatch?
            redispatches += 1
            if redispatches > REDISPATCH_CAP
              logger.warn { "[Executor] unresolved: #{step.intent} (redispatch cap #{REDISPATCH_CAP} hit); hard stop" }
              transcript.unresolved = outcome.note || step.intent
              break
            end
            logger.info { "[Executor] step #{step_no} #{step.runner} went stale → re-dispatch #{redispatches}/#{REDISPATCH_CAP}" }
            replan = @dispatcher.plan(input)
            if replan.failed? || replan.empty?
              logger.warn { "[Executor] re-dispatch produced no usable plan; hard stop" }
              transcript.unresolved = step.intent
              break
            end
            pending = replan.steps
            next
          end

          # :ok — honor an inter-step scene change before the next runner reads
          # the world. Trailing scene_dirty is left for the pre-narration rebuild.
          if @context.scene_dirty && pending.any? && @scene_manager.active
            logger.debug { "[Executor] scene_dirty after step #{step_no}; rebuilding before next step" }
            @scene_manager.exit
            @scene_manager.ensure_entered
            @context.clear_scene_dirty!
          end
        end

        logger.debug { "[Executor] chain done: #{transcript.tool_calls.size} total tool call(s)" }
      end

      def run_narration(input, transcript)
        ::Harness::CostTracker.in_subsystem(:narration) do
          user = narration_user_message(input, transcript)
          transcript.narration_prompt = user
          prose = @adapter.complete(system: narration_preamble, user: user)
          transcript.narration = compose_narration(prose, transcript.tool_calls)
        end
      end

      # The dice bracket line is a MECHANICAL outcome — like /map, it's rendered
      # by Ruby from the real resolve result, NEVER written by the narration
      # model. The model used to be asked to surface it; it fabricated rolls for
      # turns that never rolled (movement "[Transition — Movement 1 vs 0]",
      # inspection "[Scrutinize — Wisdom 16 vs 10]") and even invented failures
      # that contradicted what the engine did (narrating a failed move the
      # player had actually completed). The roll is now stripped from the
      # model's context entirely (see sanitize_tool_calls_for_narration), so it
      # has nothing to fabricate from; any `[...]` it emits anyway is discarded
      # here and replaced by the authoritative Ruby-rendered lines.
      def compose_narration(prose, tool_calls)
        body = strip_leading_brackets(prose.to_s)
        lines = resolve_bracket_lines(tool_calls)
        lines.empty? ? body : "#{lines.join("\n")}\n\n#{body}"
      end

      def strip_leading_brackets(text)
        lines = text.lines
        lines.shift while lines.first&.strip&.match?(/\A\[.*\]\z/)
        lines.shift while lines.first && lines.first.strip.empty?
        lines.join
      end

      # Authoritative bracket line per real `resolve` call, built from the raw
      # result. Combat narration is assembled separately (its round driver
      # renders its own lines) and never routes through here.
      def resolve_bracket_lines(tool_calls)
        Array(tool_calls).filter_map do |tc|
          next unless tc["name"] == "resolve"
          r = tc["result"]
          next unless r.is_a?(Hash) && r["outcome"]
          label   = r["ability_name"].to_s.strip
          label   = r["stat"].to_s.capitalize if label.empty?
          nums    = (r["roll"] && r["against"]) ? " #{r['roll']} vs #{r['against']}" : ""
          tail    = [ r["outcome"], r["margin"] ].compact.reject { |s| s.to_s.empty? }
          tail << "critical" if r["critical"]
          "[#{r['action']} — #{label}#{nums}: #{tail.join(', ')}]"
        end
      end

      # Character-initiative consumer (post-narration). Asks whether ONE present
      # NPC makes an unprompted move toward the player given what just happened
      # (the narration), commits it as an event, and returns its beat prose so
      # the caller can append it as a foregrounded trailing paragraph. Returns
      # nil when nobody acts. Failure-isolated.
      def maybe_run_initiative(transcript, narration)
        active = @scene_manager.active
        return nil unless active
        result = ::Harness::Scene::Initiative.run(
          context: @context, active: active, transcript: transcript, narration: narration, logger: logger
        )
        result && result[:beat]
      rescue StandardError => e
        logger.warn { "[Turn::Loop] initiative pass failed: #{e.class}: #{e.message}" }
        nil
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
        # Scene state is deliberately NOT injected here. The reasoning loop
        # opens each turn by calling query_scene (see reasoning.txt "OPEN
        # EVERY TURN"). This restores the iterative tool-use reflex that the
        # scene-injection optimization removed: across three playtest sessions
        # the silent-turn rate (0% → 29% → 44%) and the runaway-turn rate
        # tracked the injection — removing the "call query_scene first" anchor
        # appears to have removed the model's structural cue to engage with
        # tools at all (see execution_flows_observed.md). This is the A/B:
        # restore the anchor, hold everything else, measure whether the
        # bimodal failure collapses back toward S1's clean baseline.
        #
        # recent_events_here / dormant_historicals_here STAY as INPUT data —
        # they're orthogonal bugfixes (propose_event dup-prevention; binding
        # role-names in old event prose to dormant character_ids, the "Warden
        # ghost" fix), not scene snapshots, and don't bear on the reflex.
        payload = {
          "player_input"   => input,
          "player"         => { "id" => player.id, "name" => player.name },
          # Recent events committed at the player's current location — gives
          # the model a structural cue for "what's already been written" so
          # it doesn't re-emit propose_event with the same prose multiple
          # times in a single turn.
          "recent_events_here" => recent_events_here_payload,
          "recent_history" => recent
        }
        # Surface quests structurally relevant to the current scene. Capped
        # by visibility rule (giver present, or current step's target in/near
        # scene) so the reasoning loop isn't tempted to push unrelated
        # threads. Omitted entirely when empty.
        relevant = visible_quests_payload
        payload["relevant_quests"] = relevant if relevant.any?
        # Surface dormant historical figures at this location so the LLM
        # can map role-names in past events ("the Warden") to row ids.
        # Omitted entirely when none exist here.
        dormant = dormant_historicals_payload
        payload["dormant_historicals_here"] = dormant if dormant.any?
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
      # Dormant historical figures at the current location — characters
      # genesis spawned at first-entry (sealed with properties.dormant=true)
      # who are filtered out of present_characters but ARE structurally tied
      # to past events at this location ("The Warden ordered the walls
      # built..."). Without this surfacing the LLM has no path to map the
      # role-name in event prose ("the Warden", "the mason") to a real
      # character_id, and ends up treating those figures as ghosts —
      # narration deploys them as present, no transition/wake gets
      # committed, spatial state diverges. Each entry includes the first
      # event the figure participates in at this location, which is the
      # bridge the model needs to bind a role-name in prose to a row id.
      def dormant_historicals_payload
        loc_id = @context.player_location&.id
        return [] unless loc_id
        dormant = ::Npc.where(location_id: loc_id).select { |c|
          c.properties.is_a?(Hash) && c.properties["dormant"] == true
        }
        return [] if dormant.empty?
        dormant.map { |c|
          first_event = ::Event.joins(:event_participants)
                               .where(location_id: loc_id, event_participants: { character_id: c.id })
                               .order(:game_time).first
          summary = if first_event
            d = first_event.details.is_a?(Hash) ? first_event.details : {}
            d["summary"].presence ||
              d["trigger"].presence ||
              (d["narrative"].is_a?(Hash) ? d["narrative"]["summary"] : nil).presence
          end
          {
            "id"                 => c.id,
            "name"               => c.name,
            "subrole"            => c.subrole,
            "state"              => "dormant",
            "first_event_summary" => summary.to_s[0, 120]
          }
        }
      end

      # Last N events committed at the player's current location, freshest
      # first. Each entry carries the event id, game_time, scope, and a short
      # summary (the trigger line, falling back to the first chunk of details
      # prose). The model uses this to see what's already in the log at this
      # location so it doesn't re-emit propose_event with the same prose. Cap
      # is intentionally small (5) — enough for "did I just commit this?"
      # without burning tokens on deep history (that's what query_events is
      # for when the model genuinely needs to dig).
      RECENT_EVENTS_HERE_CAP = 5

      def recent_events_here_payload
        loc_id = @context.player_location&.id
        return [] unless loc_id
        ::Event.where(location_id: loc_id).order(id: :desc).limit(RECENT_EVENTS_HERE_CAP).map { |e|
          d = e.details.is_a?(Hash) ? e.details : {}
          summary = d["trigger"].presence ||
                    d["summary"].presence ||
                    (d["narrative"].is_a?(Hash) ? d["narrative"]["trigger"] : nil).presence ||
                    "(no summary)"
          { "id" => e.id, "t" => e.game_time, "scope" => e.scope, "summary" => summary.to_s[0, 100] }
        }
      end

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

      # The player character's identity for the narration step (name + gender).
      # nil-safe: returns name-only if gender unset, {} if no player row.
      def player_identity
        pl = ::Player.first
        return {} unless pl
        g = pl.properties.is_a?(::Hash) ? pl.properties["gender"] : nil
        { "name" => pl.name, "gender" => g }.compact
      end

      def narration_user_message(input, transcript)
        here_id = @context.player_location.id
        kept_calls, discoveries = partition_offscene_creations(transcript.tool_calls, here_id)
        # First narration of a scene gets the full static set-dressing (location
        # description + present_extras prose) so it can establish the room. Every
        # turn AFTER that, the room is already established and lives in
        # recent_history — re-feeding the static prose just invites the model to
        # reprint it verbatim (the repeated-narration failure). So later turns
        # get only the location NAME and the present SET (who/what is here, which
        # narration still needs for the no-invent / no-strand rules). scene_history
        # is empty on the first narration of a scene (it's appended after this
        # runs, and wiped on scene transition).
        establishing = scene_history.empty?
        loc = @context.player_location
        location_payload = { "id" => here_id, "name" => loc.name }
        location_payload["description"] = loc.description if establishing
        payload = {
          "player_input"   => input,
          # Who the player IS — the "you" of the narration. Without this the
          # narrator has no name for the player, so when an NPC addresses them
          # aloud it grabs a present character's name ("Maud, if you're hunting
          # ghosts," Maud says — to the player). Surfaced so dialogue can name
          # the player correctly (or use an epithet) instead of borrowing an NPC.
          "player"         => player_identity,
          "location"       => location_payload,
          "tool_calls"     => sanitize_tool_calls_for_narration(kept_calls),
          # current_scene is what's TRUE NOW. tool_calls captures what the
          # reasoning loop SAW during its turn — but the scene may have
          # rebuilt between then and now (when transition fires mid-turn,
          # the limbo fix runs Manager.exit + ensure_entered before
          # narration so the materializer populates the destination scene).
          # Any query_scene result in tool_calls captured BEFORE that
          # rebuild reflects the empty pre-materialization state. Narration
          # should trust current_scene for who/what is present; tool_calls
          # for what HAPPENED (resolve outcomes, propose_event prose, etc).
          "current_scene"  => current_scene_payload(include_extras: establishing),
          "recent_history" => scene_history.last(@history_cap)
        }
        payload["discovered_nearby"] = discoveries if discoveries.any?
        payload["unresolved"] = transcript.unresolved if transcript.unresolved
        "INPUT:\n#{JSON.pretty_generate(payload)}"
      end

      # Tool calls that create world content. A runner can create entities or
      # events at a DIFFERENT location than the player stands in (a tavern the
      # player asked about but did not walk to, its proprietor, its founding
      # event). Those records used to reach narration verbatim, and this model
      # tier renders them as the PRESENT scene — teleporting the player into
      # the new place and staging its inhabitants greeting them. Reconciling
      # "created, but the player isn't there" is judgment the weak model does
      # not have to spare, so we make it structural rather than a prompt rule.
      CREATION_TOOLS = %w[propose_location propose_character propose_item propose_event].freeze

      # Split tool_calls into [kept, discoveries]. Any creation call whose
      # target location is NOT the player's current location is removed from
      # what narration sees. New PLACES surface as flat discoveries (name +
      # description only — never staged kickoff prose) so narration can say
      # "you become aware these exist nearby" without arrival. Off-scene
      # characters / items / events are dropped entirely; the player meets them
      # only by actually going there, where the scene assembler surfaces them.
      def partition_offscene_creations(tool_calls, here_id)
        discoveries = []
        kept = tool_calls.reject { |tc|
          name = tc["name"]
          next false unless CREATION_TOOLS.include?(name)

          if name == "propose_location"
            loc_id = tc.dig("result", "location_id") || tc.dig("result", "id")
            next false if loc_id && loc_id == here_id # created AT the player's location → keep
            discoveries << {
              "name"        => tc.dig("args", "name"),
              "description" => tc.dig("args", "description")
            }.compact
            true
          else
            loc_id = tc.dig("args", "location_id")
            loc_id.present? && loc_id != here_id # off-scene character / item / event → hide
          end
        }
        [ kept, discoveries ]
      end

      # `include_extras` is false after the first narration of a scene: the
      # ambient figures (present_extras prose) are static set-dressing already
      # established in the opening narration, and re-feeding their descriptions
      # every turn is a prime driver of repeated narration. The present
      # CHARACTER set is always sent — narration needs it for the no-invent /
      # no-strand rules — but it's minimal (id/name/subrole), not prose.
      def current_scene_payload(include_extras: true)
        active = @scene_manager.active
        return { "present_characters" => [], "present_items" => [], "present_corpses" => [], "present_extras" => [] } unless active
        {
          "present_characters" => active.present_characters.map { |c|
            entry = { "id" => c.id, "name" => c.name, "subrole" => c.subrole }
            # Carry gender so narration uses the right pronouns. It's stored once
            # at spawn (Hatchery#ensure_gender!) and is otherwise invisible to the
            # narration step — which then guesses from the name and flips a
            # feminine-stored "Dushka" to "he". Not a reasoning failure; the model
            # was never told. Now it is.
            entry["gender"] = c.properties["gender"] if c.properties.is_a?(Hash) && c.properties["gender"]
            entry
          },
          "present_items"      => active.present_items.map { |i| { "id" => i.id, "name" => i.name } },
          "present_corpses"    => active.present_corpses.map { |c| { "id" => c.id, "name" => c.name } },
          "present_extras"     => include_extras ? active.present_extras : []
        }
      end

      # Strip reasoning-loop-only flavor (internal_state, agenda) from
      # query_scene results before forwarding to the narration step. These
      # fields are scene-entry mood snapshots intended
      # to inform the LLM's JUDGMENT — they are NOT meant to be rendered
      # verbatim in prose. Without this filter the narrator regurgitates
      # "Rask drums his axe handle" for the rest of the scene even after
      # Rask has been struck and is bleeding, because internal_state is
      # generated once at scene entry and never refreshed mid-scene.
      # Narration should render NPC state from what JUST happened (the
      # other tool results — resolve outcomes, mutate_character calls,
      # propose_event details) plus recent_history, not from the cached
      # mood line.
      NARRATION_HIDDEN_FIELDS = %w[internal_state agenda].freeze

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
