module Harness
  # Single chokepoint for game-time advancement. Every minute the clock moves
  # forward goes through here so we get one auditable trail and consistent
  # scene-rebuild semantics.
  #
  # Time-bearing surfaces (the only callers that should ever advance time):
  #   - Tools::Resolve        — LLM-declared time_minutes per action
  #   - Tools::Transition     — flat per-move cost (intra-city sublocation hop)
  #   - Tools::Travel         — geometric distance × terrain multiplier per segment
  #   - Tools::ProposeEvent   — LLM-declared time_minutes (forward only)
  #   - Tools::PassTime       — explicit waits/rests (LLM-declared duration)
  #
  # Time-free surfaces (must NOT call advance):
  #   - All query_* tools, mutate_* — meta-state ops, not in-fiction
  #     player time. Mutations get bundled with whichever event caused them.
  #
  # Scene rebuilds are EXPLICIT, not accrual-driven. They happen when the
  # player actually changes scene (transition / travel, which set scene_dirty
  # themselves) or deliberately skips time (pass_time, which dirties when the
  # skip is substantial — see IN_SCENE_THRESHOLD). The clock does NOT rebuild
  # the scene just because conversation/action minutes piled past an hour:
  # that fired a destructive same-location rebuild mid-conversation (wiped
  # scene-local narration continuity, re-rolled internal states + agendas) —
  # the "scene whiplash" failure. Catch-up answers "what happened here while I
  # was AWAY"; a player sitting and talking was never away, so there is nothing
  # to catch up and nothing to justify the rug-pull. The constant lives here
  # because pass_time reads it to decide whether an explicit skip is long
  # enough to warrant a rebuild.
  module Clock
    IN_SCENE_THRESHOLD = 60

    def self.advance(context, minutes:, reason:, logger: Rails.logger)
      raise ArgumentError, "minutes must be a non-negative integer (got #{minutes.inspect})" unless minutes.is_a?(Integer) && minutes >= 0
      return context.game_time if minutes.zero?

      before = context.game_time || 0
      context.game_time = before + minutes
      logger.info { "[Clock] +#{minutes}min reason=#{reason} #{before} -> #{context.game_time}" }

      maybe_fire_pending_appearances!(context, logger)
      context.game_time
    end

    # Mid-scene PA fire. Called after every clock advance: if any
    # unresolved PA targeting the player came due during this tick AND
    # is in scope of the player's current location, realize it now.
    # The new character is materialized at the player's location; subsequent
    # query_scene calls in the same turn will surface them via a fresh
    # Scene::Assembler query (active scene snapshot is set stale via
    # scene_dirty so the next turn rebuilds full flavor — internal_state,
    # agendas, catch-up, etc).
    #
    # Failure non-fatal — same posture as the maybe_run_* hooks in the Manager.
    def self.maybe_fire_pending_appearances!(context, logger)
      scene = context.active_scene
      return unless scene
      player = ::Player.first
      return unless player

      resolved = ::Harness::Scene::PendingAppearanceResolver
        .new(llm_grunt: context.llm_grunt, logger: logger)
        .resolve(
          target_character:  player,
          current_location:  scene.location,
          current_game_time: context.game_time
        )

      return if resolved.empty?

      context.scene_dirty = true
      logger.info { "[Clock] mid-scene PA fired: #{resolved.size} resolution(s); scene_dirty=true" }
    rescue StandardError => e
      logger.warn { "[Clock] mid-scene PA resolution failed: #{e.class}: #{e.message}" }
    end

  end
end
