require "fileutils"
require "json"

module Harness
  module Turn
    # Skeleton of the runtime turn. One call = one player input in, one
    # rendered turn out (typed parts + their plain-text join). The caller
    # (TTY, web handler, spec, REPL) loops over this. The loop knows nothing
    # about where input came from.
    #
    # Per turn:
    #   1. Enter/rebuild the scene.
    #   2. Dispatch the input to an ordered plan and run its chained runners
    #      (or drive the structured combat slot mid-fight).
    #   3. Render the committed tool calls MECHANICALLY into typed parts
    #      (Turn::Parts — no model call). Staged
    #      dialogue and the initiative beat are the only LLM-authored text,
    #      and each renders verbatim from its own organ.
    #   4. Persist a TurnLog transcript.
    #   5. Optionally snapshot the SQLite file.
    #   6. Rebuild the scene on the next turn if scene_dirty was set.
    #
    # The law: causal authority = rendering authority. The organ that
    # committed a change describes it (or Ruby does, from its tool result);
    # no voice renders another voice's output; nothing describes what
    # didn't happen.
    class Loop
      # Hard cap on prior turns retained in the context history buffer. Loose
      # for now — tighten when we measure token usage against a real adapter.
      DEFAULT_HISTORY_CAP = 50

      # How many times a single turn may re-dispatch when a runner reports its
      # plan went stale under the world (:redispatch). On exhaustion the turn
      # HARD-STOPS and logs `unresolved:` — the loud dead-end (locked decision
      # #3), and the guard against re-dispatch becoming its own runaway (#6).
      REDISPATCH_CAP = 2

      attr_reader :logger

      def initialize(
        adapter:,
        context:,
        history_cap: DEFAULT_HISTORY_CAP,
        snapshot_dir: nil,
        scene_manager: nil,
        registry: nil,
        logger: Rails.logger
      )
        @adapter              = adapter
        @context              = context
        @history_cap          = history_cap
        @snapshot_dir         = snapshot_dir
        @logger               = logger
        @scene_manager        = scene_manager || ::Harness::Scene::Manager.new(context: context, logger: logger)

        # Runner registry. Only built runners live here; a plan step naming
        # anything else degrades to a safe inspection step (see
        # run_state_machine). Injectable for tests.
        @registry = registry || {
          "inspection"   => ::Harness::Runners::Inspection.new(logger: logger),
          "movement"     => ::Harness::Runners::Movement.new(logger: logger),
          "conversation" => ::Harness::Runners::Conversation.new(logger: logger),
          "worldbuilding" => ::Harness::Runners::Worldbuilding.new(logger: logger),
          # No "dice" runner — a roll is a mechanism INSIDE an interaction, not
          # its own step. Each runner rolls when its own action is contested
          # (conversation → persuasion, environment → climb/force/lockpick,
          # inventory → loot a container). Movement NEVER rolls. The grammar's
          # label enum no longer offers "dice" at all.
          "environment"  => ::Harness::Runners::Environment.new(logger: logger),
          "inventory"    => ::Harness::Runners::Inventory.new(logger: logger),
          "cast"         => ::Harness::Runners::Cast.new(logger: logger),
          "time-skip"    => ::Harness::Runners::TimeSkip.new(logger: logger),
          "combat"       => ::Harness::Runners::Combat.new(logger: logger),
          "meta"         => ::Harness::Runners::Meta.new(logger: logger)
        }
        @dispatcher = ::Harness::Dispatcher.new(
          context: context, scene_manager: @scene_manager, registry: @registry, logger: logger
        )
        logger.info { "[Turn::Loop] runners=[#{@registry.keys.join(', ')}]" }
      end

      # Returns the Transcript for the turn (already persisted).
      # `seed:` forces this turn's sampler/dice seed (replay-rig retry);
      # normally one is rolled fresh and stamped onto the TurnLog.
      def run_turn(input:, seed: nil)
        ::Harness::CostTracker.reset_turn!
        ::Harness::Timing.reset_turn!
        ::Harness::Turn::Receipt.begin_turn!(game_time: @context.game_time)
        @context.reset_per_turn_counters!

        # Pin this turn's randomness: the LLM sampler seed (adapter sends it
        # per request) and the dice RNG. Same seed on a rewound retry = same
        # rolls, same sampling — the fix under test is the only delta.
        turn_seed = seed || (Random.new_seed % 2_147_483_647)
        ::Harness::LLM::Seed.current = turn_seed
        ::Harness::RNG.reset!(turn_seed)

        # Tools reach the LLM via context.llm_grunt (small-model, hot path
        # for materialization) or context.llm_nuance (runner emits).
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
        transcript.llm_seed = turn_seed
        logger.info { "[Turn::Loop] input=#{input.inspect} location=#{@context.player_location.name}" }

        begin
          if @scene_manager.active&.in_combat?
            # Already mid-fight: the player's input IS their combat slot. Skip
            # the dispatcher (it would route to the combat ENTRY runner, get
            # "already in combat", and re-dispatch to the cap) and drive the
            # slot via Combat::PlayerTurn — ONE structured call on the narrow
            # slot surface, the state-machine replacement for the agentic
            # reasoning loop that used to flail here (~6 calls per attack).
            # The round-driver hand-off below runs the NPC slots.
            logger.debug { "[Turn::Loop] already in combat → structured player slot (dispatcher skipped)" }
            run_player_slot(input, transcript)
          else
            run_state_machine(input, transcript)
          end

          # Combat hand-off. While scene.in_combat?, Combat::Loop processes
          # NPC slots around the player's slot. The loop YIELDS at fresh
          # player slots (end_reason: :yielded) so the next turn can drive
          # the player's next combat slot. On real termination
          # (:victory / :player_died / :player_fled / :all_fled / :round_cap_reached)
          # combat ends and scene_dirty is raised by the loop.
          combat_result = nil
          if @scene_manager.active&.in_combat?
            combat_result = run_combat(transcript)
          end

          # Missed meetings break mechanically once the clock is past due —
          # runs after the turn's time advancement so this turn's initiative
          # and next turn's payloads see the breach. Non-fatal inside.
          ::Obligation.sweep_breaches!(@context.game_time, logger: logger)

          # If the turn fired a transition / travel / threshold-
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

          # Player declined a scene change at the confirmation gate. The turn is
          # a no-op: narrate nothing, run no initiative, record nothing to scene
          # history or conversation memory — it leaves no trace, as if the input
          # were never sent. Only the OOC notice (set by the executor) is shown.
          if transcript.halted
            transcript.narration = nil
            transcript.notice  ||= halted_notice(nil)
            return transcript   # `ensure` still persists the TurnLog + snapshots
          end

          # Render the turn MECHANICALLY: typed parts from the committed tool
          # calls, in causal order (Parts module — no model call). The law is
          # causal authority = rendering authority. Combat with content
          # replaces the list (its round driver owns its prose).
          transcript.parts = if combat_result && (combat_result.round_summaries.any? || combat_result.player_fled_resolution)
            [ { kind: :combat, text: assemble_combat_narration(combat_result) } ]
          else
            ::Harness::Turn::Parts.compose(
              transcript: transcript, context: @context, scene: @scene_manager.active
            )
          end
          transcript.parts.each { |p| p[:text] = scrub_player_reference(p[:text]) }
          narration = join_parts(transcript.parts)
          transcript.narration = narration

          # Character initiative — runs AFTER narration on purpose, so the
          # consumer reads what just happened and appends ONE present NPC's
          # unprompted move as its own foregrounded trailing beat (the system
          # supplying the engagement the LLM never volunteers). Skipped during
          # combat (it owns its own beats) and when the player is leaving the
          # scene (the agenda belongs to the scene being left).
          # Initiative is the world piping up on a turn the player did NOT spend
          # talking. When NPCs actually SPOKE this turn, they've had their say —
          # bolting an unprompted beat on top is the "goober forced to speak"
          # noise. But a polled-and-declined turn (the coin-trick class: the
          # conversation runner ran, every voice stayed silent) is exactly the
          # quiet room initiative exists for — someone MAY react to the act.
          # So the gate is "a staged line exists", not "the runner ran".
          player_conversed = Array(transcript.tool_calls).any? { |tc|
            tc["name"] == "propose_event" && tc.dig("result", "staged")
          }
          unless combat_result || @context.scene_dirty || @scene_manager.active&.in_combat? || player_conversed
            beat = maybe_run_initiative(transcript, narration)
            if beat && !beat.empty?
              # The beat prose is the voicing organ's own output; scrub the
              # engine word "the player" like every other part.
              transcript.parts << { kind: :beat, text: scrub_player_reference(beat) }
              narration = join_parts(transcript.parts)
              transcript.narration = narration
            end
          end

          # Perception — the player's eyes, DELTA-GATED (v2, ruled
          # 2026-08-14): eyes fire when the OBSERVABLE VIEW changed or the
          # player looked, and stay silent otherwise. The view is the whole
          # ledger — every field Perception.observable_view exposes (place,
          # phase, roster, appearance, doing, bearing, alterations, ...)
          # triggers on change automatically; no per-attribute gate wiring.
          # The stamp is the view's digest at last successful render, held on
          # the Active scene — it dies with the scene, so an arrival fires
          # as establishment for free; a flaked call doesn't stamp, so the
          # gate stays open to retry. A no-change conversation turn pays
          # nothing (the view build is pure SQL). Runs dead last so it reads
          # post-commit state and every voice that spoke, including the
          # beat. DISPLAY-ONLY: `narration` was joined above WITHOUT this
          # part, so scene history, the context buffer, and every LLM
          # payload never see the eyes' prose.
          unless combat_result || @scene_manager.active&.in_combat?
            active = @scene_manager.active
            view   = ::Harness::Turn::Perception.observable_view(@context)
            digest = ::Harness::Turn::Perception.view_digest(view)
            looked = Array(transcript.runners_ran).include?("inspection")
            # The stamp is {digest, view} from the last successful render:
            # digest = the no-change fast path, view = what the delta diffs
            # against. (A legacy bare-string stamp from an older save reads
            # as no stamp — one establishment render, then normal.)
            stamp = active&.perceived_view
            stamp = nil unless stamp.is_a?(::Hash)
            if looked || active.nil? || stamp.nil? || stamp["digest"] != digest
              # An arrival or an explicit look ESTABLISHES: full view, and
              # extras feed only here (no writer, near-never a delta — the
              # narrations list is still empty on the scene's first render;
              # record_narration runs below). A mere attribute shift renders
              # ONLY the delta — the scene is not re-established because
              # somebody coughed.
              establishing = looked || stamp.nil? || Array(active&.narrations).empty?
              eyes = if establishing
                ::Harness::Turn::Perception.render(
                  context: @context, parts: transcript.parts, view: view,
                  include_figures: looked || Array(active&.narrations).empty?, logger: logger)
              else
                delta = ::Harness::Turn::Perception.view_delta(stamp["view"], view)
                # A changed person who STAGED A LINE this turn already voiced
                # their own shift — the eyes re-voicing it in the very next
                # sentence is jarring (ruled). Their entries drop; a decliner's
                # silent snub has no line, so it stays and renders. If nothing
                # else moved, the change is absorbed into the stamp silently.
                spoke = staged_speaker_names(transcript)
                if spoke.any? && delta["people"].is_a?(Array)
                  delta["people"] = delta["people"].reject { |p| spoke.include?(p["name"]) }
                  delta.delete("people") if delta["people"].empty?
                end
                if delta.empty?
                  active&.perceived_view = { "digest" => digest, "view" => view }
                  nil
                else
                  ::Harness::Turn::Perception.render_delta(
                    context: @context, parts: transcript.parts, delta: delta,
                    place: view["place"], logger: logger)
                end
              end
              if eyes
                transcript.record_tool_calls([ { "name" => "display_perception", "args" => { "text" => eyes }, "result" => { "rendered" => true } } ])
                transcript.parts << { kind: :perception, text: scrub_player_reference(eyes) }
                active&.perceived_view = { "digest" => digest, "view" => view }
              end
            end
          end

          # Record only the diegetic narration to scene history (keeps the
          # fiction record clean). The OOC notice below is display-only. A turn
          # with nothing diegetic to say (a meta-only no-op) records nothing.
          @scene_manager.record_narration(input, narration) unless narration.to_s.strip.empty?
          @context.append_turn(input: input, narration: narration)
          transcript.notice = unresolved_notice(transcript.unresolved) if transcript.unresolved
          trim_history!
        rescue StandardError => e
          transcript.error = "#{e.class}: #{e.message}"
          logger.error { "[Turn::Loop] turn failed: #{transcript.error}" }
          raise
        ensure
          # Flush order matters: the scene buffer must be IN the DB before the
          # file snapshot runs, or the snapshot is a save-state with amnesia.
          persist_session_state!
          transcript.persist!
          snapshot_db(transcript.turn_log) if transcript.turn_log
          ::Harness::Turn::Receipt.finalize!(transcript: transcript, game_time: @context.game_time)
        end

        transcript
      end

      # Snapshot the CURRENT state as the floor below the next turn — called
      # once at session start (debug mode) so `/debug rewind` after the very
      # first turn of a session has somewhere to land.
      def baseline_snapshot!
        persist_session_state!
        last = ::TurnLog.maximum(:turn_number) || 0
        snapshot_db(::TurnLog.new(turn_number: last))
      end

      private

      # Names of NPCs who staged a line this turn — their prose already voiced
      # their own state shift. Resolved from the in-RAM scene snapshot, no DB
      # hit; a promoted extra absent from the snapshot just isn't suppressed.
      def staged_speaker_names(transcript)
        ids = Array(transcript.tool_calls).filter_map { |tc|
          next unless tc["name"] == "propose_event" && tc.dig("result", "staged")
          Array(tc.dig("args", "participants"))
            .find { |p| p.is_a?(Hash) && p["role"].to_s == "actor" }&.dig("character_id")
        }
        return [] if ids.empty?
        Array(@scene_manager.active&.present_characters)
          .select { |c| ids.include?(c.id) }.map(&:name)
      end

      # A justified fourth-wall break: when a turn dead-ends, tell the PLAYER
      # (out of character) what the engine couldn't do, so they can rephrase.
      # This is distinct from the diegetic non-event narration — that keeps the
      # fiction intact ("the way isn't clear"); this names the engine limit.
      def unresolved_notice(reason)
        r = reason.to_s.strip
        r = "that action couldn't be carried out" if r.empty?
        "( ⚙ Out of character — the engine couldn't resolve: #{r}. Try rephrasing or being more specific. )"
      end

      # Replace the engine phrase "the player" (and its possessive) in prose with
      # the player character's actual name — the model is handed the name but
      # sometimes falls back to the engine word. Narrow on purpose: only the
      # definite phrase "the player['s]" (never a bare "player", which can mean a
      # dice-player in a crowd). No-op when there's no player row.
      def scrub_player_reference(text)
        return text if text.nil? || text.empty?
        name = ::Player.first&.name
        return text if name.to_s.strip.empty?
        text.gsub(/\bthe player(’s|'s)?\b/i) { "#{name}#{Regexp.last_match(1) ? "’s" : ""}" }
      end

      # Player declined a scene change at the confirmation gate. Tell them, out
      # of character, that nothing happened and to restate their intent clearly.
      def halted_notice(reason)
        r = reason.to_s.strip
        tail = r.empty? ? "" : " (#{r})"
        "( ⚙ Out of character — held your place; nothing happened#{tail}. Say plainly where you want to go, e.g. \"go to the mending shed\", or keep doing what you were doing. )"
      end

      # State-machine turn: dispatch → ordered plan → chained runners.
      # The agentic loop is GONE (deleted 2026-08-11; it persisted invented
      # dialogue as events — the Ilyrra flail). Every failure shape degrades
      # to a safe inspection step instead, LOUD in the log.
      def run_state_machine(input, transcript)
        plan = @dispatcher.plan(input)

        if plan.failed? || plan.empty?
          logger.info { "[Executor] no usable plan (#{plan.failed? ? 'parse-fail' : 'empty'}) → single inspection step" }
          fallback = ::Harness::Dispatcher::Step.new(runner: "inspection", intent: input, args: {})
          return execute_chain([ fallback ], input, transcript)
        end

        steps = plan.steps.map do |step|
          next step if @dispatcher.built?(step.runner)
          logger.info { "[Executor] unknown runner #{step.runner.inspect} → inspection for that step" }
          ::Harness::Dispatcher::Step.new(runner: "inspection", intent: step.intent, args: step.args || {})
        end

        execute_chain(steps, input, transcript)
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
          transcript.runners_ran << step.runner
          transcript.record_tool_calls(outcome.tool_calls)
          outcome.tool_calls.each do |tc|
            next unless tc["name"] == "propose_location"
            r = tc["result"]
            chain_created_locations << { "id" => r["location_id"], "type" => r["type"], "name" => r["name"] } if r.is_a?(Hash) && r["location_id"]
          end
          logger.info { "[Executor] step #{step_no} #{step.runner} → #{outcome.status} (#{outcome.tool_calls.size} tool call(s))#{outcome.note ? " #{outcome.note}" : ''}" }

          # A deterministically-dead step (referent doesn't exist) stalls
          # alone; the chain continues. The intent (not the mechanical note)
          # goes to `unresolved` so the stall renders diegetically (Parts).
          if outcome.skipped?
            logger.info { "[Executor] step #{step_no} #{step.runner} skipped (#{outcome.note}); chain continues" }
            transcript.unresolved ||= step.intent.to_s.strip.presence || outcome.note
            next
          end

          if outcome.combat?
            logger.info { "[Executor] combat terminator at step #{step_no}; aborting #{pending.size} remaining step(s)" }
            break
          end

          if outcome.halted?
            logger.info { "[Executor] player halted the turn at step #{step_no} (#{outcome.note}); aborting #{pending.size} remaining step(s)" }
            transcript.halted = true
            transcript.notice = halted_notice(outcome.note)
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
            # A pinned turn seed makes an identical replan DETERMINISTIC — the
            # mending-light loop re-planned [movement → combat] three times
            # verbatim and burned the cap on guaranteed reruns. Perturb the
            # sampler seed per attempt (derived from the turn seed, so replays
            # still reproduce) to make each replan a genuine second sample;
            # the turn seed is restored for everything after.
            base_seed = ::Harness::LLM::Seed.current
            begin
              ::Harness::LLM::Seed.current = base_seed + redispatches if base_seed
              replan = @dispatcher.plan(input)
            ensure
              ::Harness::LLM::Seed.current = base_seed
            end
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

      # Join typed parts into the plain narration string recorded to scene
      # history and the session log. Colors/styling never happen here — the
      # presenter (Render.parts) styles by kind; the buffer stores plain text.
      def join_parts(parts)
        Array(parts).map { |p| p[:text].to_s }.reject { |t| t.strip.empty? }.join("\n\n")
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

      # The player's mid-combat slot: one structured call (Combat::PlayerTurn).
      # The executed action is recorded on the transcript like any runner
      # tool call, so dice brackets, the narration sanitizer, and
      # /debug all read it unchanged. nil = the input wasn't a combat action;
      # nothing recorded, the slot stays fresh and Combat::Loop yields again.
      def run_player_slot(input, transcript)
        ::Harness::CostTracker.in_subsystem(:combat_player_turn) do
          out = ::Harness::Combat::PlayerTurn.run(
            player:  ::Player.first,
            input:   input,
            scene:   @scene_manager.active,
            adapter: @adapter,
            context: @context,
            logger:  logger
          )
          transcript.record_tool_call(out[0], out[1]) if out
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

      def trim_history!
        return if @context.history.size <= @history_cap
        overflow = @context.history.size - @history_cap
        @context.history.shift(overflow)
      end

      # Flush cross-turn in-memory state to the singleton session_states row:
      # the active scene buffer (nil between scenes — the row always mirrors
      # the CURRENT scene, so a scene change wipes the old buffer at the next
      # boundary), the conversation history, and the game clock. Stamped with
      # git SHA + prompt-file hash so a restore can detect wiring drift.
      # Non-fatal: a failed flush must never kill the turn.
      def persist_session_state!
        row = ::SessionState.first_or_initialize
        row.update!(
          location_id: @context.player_location&.id,
          scene:       ::Harness::Scene::Serializer.dump(@scene_manager.active, logger: logger),
          history:     @context.history,
          game_time:   @context.game_time,
          git_sha:     wiring_stamp[:git_sha],
          prompt_hash: wiring_stamp[:prompt_hash]
        )
      rescue StandardError => e
        logger.warn { "[Turn::Loop] session-state flush failed: #{e.class}: #{e.message}" }
      end

      # Computed once per session — the stamps written into session_states
      # (and thus into every snapshot). A restore compares against the live
      # process's values and warns on drift.
      def wiring_stamp
        @wiring_stamp ||= ::Harness::Debug::Replay.wiring_stamp
      end

      # Per-turn save-state: VACUUM INTO writes a complete, WAL-independent
      # copy of the SQLite file (FileUtils.cp could miss un-checkpointed WAL
      # frames). The session_states flush above already put the scene buffer
      # and stamps inside, so the file is the whole truth.
      def snapshot_db(turn_log)
        return unless @snapshot_dir
        db_path = ActiveRecord::Base.connection_db_config.database
        return unless db_path && File.exist?(db_path)

        FileUtils.mkdir_p(@snapshot_dir)
        target = File.join(@snapshot_dir, "turn_#{turn_log.turn_number}.sqlite")
        File.delete(target) if File.exist?(target) # VACUUM INTO refuses to overwrite
        ActiveRecord::Base.connection.execute(
          "VACUUM INTO #{ActiveRecord::Base.connection.quote(target)}"
        )
        logger.debug { "[Turn::Loop] snapshot -> #{target}" }
      rescue StandardError => e
        logger.warn { "[Turn::Loop] snapshot failed: #{e.message}" }
      end
    end
  end
end
