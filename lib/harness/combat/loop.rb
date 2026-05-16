module Harness
  module Combat
    # The round driver. Owns the initiative loop; the LLM owns the brain of
    # each individual slot.
    #
    # Cross-turn structure (THIS is the load-bearing model):
    # - Combat persists across turns via scene.combat. One player turn drives
    #   one combat slot — the player's. The round driver processes NPC slots
    #   around it.
    # - On each turn that scene.in_combat?, the reasoning loop fires with
    #   COMBAT_TOOLS active. The player calls resolve/move_to/escape/end_turn;
    #   those tools record into state.current_round_actions and mark tokens.
    # - After the reasoning loop returns, Turn::Loop calls Combat::Loop.run,
    #   which:
    #     1. Pre-flight termination check (caught: player_died from a self-
    #        inflicted resolve, player_fled via escape, victory if the player
    #        killed the last enemy).
    #     2. Walks initiative from state.initiative_index:
    #        - Player slot, exercised → close it, advance.
    #        - Player slot, fresh → YIELD (return end_reason: :yielded).
    #        - NPC slot → NpcTurn → advance.
    #     3. End-of-round narration (reads state.current_round_actions).
    #     4. Termination check.
    #     5. end_round! → state.round++; reset tokens + action buffer.
    #     6. Loop: process slots in new round until next yield/termination.
    #
    # On yield, scene.combat stays set. scene_dirty is NOT raised. Combat
    # continues on the next player input. On termination (or MAX_ROUNDS cap),
    # scene.end_combat! fires and scene_dirty is set.
    class Loop
      Result = Struct.new(:end_reason, :rounds, :round_summaries, :player_fled_resolution, keyword_init: true)

      MAX_ROUNDS = 30  # hard safety cap; combats should resolve well before this

      def initialize(context:, adapter: nil, logger: ::Rails.logger)
        @context = context
        @adapter = adapter
        @logger  = logger
      end

      def run
        scene = @context.active_scene
        raise "no active combat" unless scene&.in_combat?

        state            = scene.combat
        round_summaries  = []
        end_reason       = nil
        flee_resolution  = nil

        log_entry(scene, state)

        # Pre-flight: the reasoning loop may have already ended combat via
        # the player's actions (killed the last enemy, escaped, died). Catch
        # it before we narrate a vacuous round.
        end_reason = ::Harness::Combat::Termination.evaluate(scene)
        if end_reason
          @logger&.info { "[Combat::Loop] pre-flight termination reason=#{end_reason} round=#{state.round}" }
          flee_resolution = run_player_fled_resolution(scene, []) if end_reason == :player_fled
          return finalize(scene, end_reason, round_summaries, flee_resolution)
        end

        # Walk initiative; yield at a fresh player slot. Per-call bound on
        # iterations so a misbehaving loop can't spin forever.
        (MAX_ROUNDS * 2).times do
          yielded = run_slots(scene, state)
          if yielded
            @logger&.info { "[Combat::Loop] yielding at fresh player slot round=#{state.round} index=#{state.initiative_index} rounds_completed=#{round_summaries.size}" }
            return Result.new(
              end_reason:             :yielded,
              rounds:                 round_summaries.size,
              round_summaries:        round_summaries,
              player_fled_resolution: nil
            )
          end

          # All slots processed for this round. Narrate, then check.
          narration = ::Harness::Combat::EndOfRoundNarration.run(
            round:   state.round,
            actions: state.current_round_actions,
            llm:     @context.llm_grunt,
            logger:  @logger
          )
          round_summaries << {
            "round"     => state.round,
            "actions"   => state.current_round_actions.dup,
            "narration" => narration
          }
          state.last_round_summary = narration
          @logger&.info { "[Combat::Loop] end-of-round narration round=#{state.round} actions=#{state.current_round_actions.size} narration=#{narration.to_s.lines.first&.strip&.slice(0, 120).inspect}" }

          end_reason = ::Harness::Combat::Termination.evaluate(scene)
          if end_reason
            @logger&.info { "[Combat::Loop] end-of-round termination reason=#{end_reason} round=#{state.round}" }
            flee_resolution = run_player_fled_resolution(scene, round_summaries) if end_reason == :player_fled
            break
          end

          @logger&.info { "[Combat::Loop] advancing round #{state.round} -> #{state.round + 1}" }
          state.end_round!

          if state.round > MAX_ROUNDS
            end_reason = :round_cap_reached
            break
          end
        end

        end_reason ||= :round_cap_reached
        finalize(scene, end_reason, round_summaries, flee_resolution)
      end

      private

      def log_entry(scene, state)
        sides_summary = state.sides.group_by { |_id, side| side }.map { |side, pairs|
          ids = pairs.map(&:first)
          names = ids.map { |id| ::Character.find_by(id: id)&.name || "?" }
          "#{side}=[#{ids.zip(names).map { |i, n| "#{i}:#{n}" }.join(',')}]"
        }.join(" | ")
        @logger&.info { "[Combat::Loop] entering run round=#{state.round} initiative=#{state.initiative.inspect} index=#{state.initiative_index} sides={#{sides_summary}}" }
      end

      def finalize(scene, end_reason, round_summaries, flee_resolution)
        @logger&.info { "[Combat::Loop] finalize end_reason=#{end_reason} rounds=#{round_summaries.size}" }
        scene.end_combat!
        @context.scene_dirty = true

        Result.new(
          end_reason:             end_reason,
          rounds:                 round_summaries.size,
          round_summaries:        round_summaries,
          player_fled_resolution: flee_resolution
        )
      end

      def run_player_fled_resolution(scene, round_summaries)
        ::Harness::Combat::PlayerFledResolution.run(
          scene:         scene,
          fight_summary: round_summaries.map { |r| r["narration"] }.join("\n\n"),
          llm:           @context.llm_grunt,
          context:       @context,
          logger:        @logger
        )
      end

      # Walks initiative slots from state.initiative_index. Returns:
      #   true  — yielded at a fresh player slot. State is left at that slot;
      #           the next turn's reasoning loop will exercise it, then a
      #           subsequent run_combat call resumes after.
      #   false — round complete (initiative_index has advanced past end of
      #           initiative). Caller runs end-of-round narration + term check.
      def run_slots(scene, state)
        while state.initiative_index < state.initiative.size
          actor_id = state.current_actor_id
          actor    = ::Character.find_by(id: actor_id)

          # Actor removed mid-round (escaped) or unknown: skip silently.
          unless actor && state.combatant?(actor_id)
            @logger&.info { "[Combat::Loop] slot skip — actor_id=#{actor_id} not a combatant (escaped/removed)" }
            state.advance_slot!
            next
          end

          # Dead actors skip. Match Assembler's partition: max_hp>0 AND
          # current_hp<=0 (uninitialized rows with max_hp=0 still count).
          if actor.max_hp.to_i > 0 && actor.current_hp.to_i <= 0
            @logger&.info { "[Combat::Loop] slot skip — #{actor.name} (id=#{actor.id}) is dead" }
            state.advance_slot!
            next
          end

          if actor.is_a?(::Player)
            handled = process_player_slot(state, actor)
            return true if handled == :yielded
            # handled == :advanced — keep walking
          elsif @adapter
            @logger&.info { "[Combat::Loop] slot npc #{actor.name} (id=#{actor.id}) round=#{state.round} pos=#{state.position_of(actor.id)} hp=#{actor.current_hp}/#{actor.max_hp}" }
            ::Harness::Combat::NpcTurn.run(
              npc:                actor,
              scene:              scene,
              last_round_summary: state.last_round_summary,
              adapter:            @adapter,
              context:            @context,
              logger:             @logger
            )
            state.advance_slot!
          else
            # Test path with no adapter — auto end_turn so the loop progresses.
            @logger&.debug { "[Combat::Loop] slot test-path auto-end_turn for #{actor.name} (id=#{actor.id})" }
            ::Harness::Combat::Tools::EndTurn.new.call({ "actor_id" => actor.id }, @context)
            state.advance_slot!
          end
        end

        false
      end

      # Player slot policy:
      #   - If the player has any token spent (acted or moved) OR no adapter
      #     is wired (test path), close the slot and advance.
      #   - Otherwise yield, so the next player turn's reasoning loop can
      #     exercise it.
      # This implements the "one player input per combat slot" rule. The
      # reasoning loop's combat-mode tools mark tokens; if nothing marked
      # them, the player skipped (queried only, or said something non-combat)
      # — in production that means we wait for fresh input, in tests we
      # auto-close so the loop terminates.
      def process_player_slot(state, player)
        any_token_spent = state.acted?(player.id) || state.moved?(player.id)

        if any_token_spent
          @logger&.info { "[Combat::Loop] slot player advance round=#{state.round} acted=#{state.acted?(player.id)} moved=#{state.moved?(player.id)} pos=#{state.position_of(player.id)}" }
          state.mark_acted!(player.id)
          state.mark_moved!(player.id)
          state.advance_slot!
          return :advanced
        end

        if @adapter.nil?
          @logger&.debug { "[Combat::Loop] slot player test-path auto-end_turn (no adapter)" }
          ::Harness::Combat::Tools::EndTurn.new.call({ "actor_id" => player.id }, @context)
          state.advance_slot!
          return :advanced
        end

        :yielded
      end
    end
  end
end
