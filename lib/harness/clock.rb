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
  # Scene-rebuild trigger: when accumulated in-scene time crosses
  # IN_SCENE_THRESHOLD, scene_dirty is set so the next turn rebuilds the scene
  # (catch-up sim runs, internal-state regenerates, present-character set
  # refreshed). This catches the "player sat in the tavern for an hour
  # chatting" case that no explicit transition or pass_time would otherwise
  # mark dirty. Transition keeps its own explicit scene_dirty=true — moving
  # always rebuilds, regardless of how little time the move cost.
  module Clock
    IN_SCENE_THRESHOLD = 60

    def self.advance(context, minutes:, reason:, logger: Rails.logger)
      raise ArgumentError, "minutes must be a non-negative integer (got #{minutes.inspect})" unless minutes.is_a?(Integer) && minutes >= 0
      return context.game_time if minutes.zero?

      before = context.game_time || 0
      context.game_time = before + minutes
      logger.info { "[Clock] +#{minutes}min reason=#{reason} #{before} -> #{context.game_time}" }

      maybe_fire_pending_appearances!(context, logger)
      maybe_dirty_scene!(context, logger)
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

    def self.maybe_dirty_scene!(context, logger)
      scene = context.active_scene
      return unless scene
      return if context.scene_dirty
      entered_at = scene.entered_at_game_time
      return unless entered_at

      in_scene = context.game_time - entered_at
      if in_scene >= IN_SCENE_THRESHOLD
        context.scene_dirty = true
        logger.info { "[Clock] scene_dirty triggered: in_scene=#{in_scene}min crossed threshold=#{IN_SCENE_THRESHOLD}min" }
      end
    end
  end
end
