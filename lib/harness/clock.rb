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

      context.game_time
    end
  end
end
