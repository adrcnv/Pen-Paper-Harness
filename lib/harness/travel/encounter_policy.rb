module Harness
  module Travel
    # Decides whether an encounter fires this segment, and which bucket it
    # belongs to. Pure Ruby — no LLM. Tunable constants today; obvious YAML
    # extraction point when more variety lands (biome-specific weights,
    # weather modifiers, sub-templates per bucket — classic D&D encounter
    # tables shape).
    #
    # v1 buckets:
    #   social     — wandering merchant, traveling family, patrol, pilgrim
    #   discovery  — shrine with a hermit, abandoned cottage with a squatter,
    #                ruined chapel with a single occupant
    #   combat     — bandits at a defile, marauders at a rotted shrine, raiders
    #                watching the road. Hostile NPCs that initiate fighting.
    #
    # WEIGHTS BELOW ARE PLAYTEST MODE — combat is set to 100% so every fired
    # encounter is a fight. Once combat is verified end-to-end (resolve →
    # damage → HP → downed → XP) the long-term weights should land roughly:
    #
    #   social    : 0.55
    #   discovery : 0.30
    #   combat    : 0.15
    #
    # That puts hostile encounters at ~1.5% of traversal segments overall
    # (10% encounter-rate × 15% combat-bucket × cooldown gating).
    #
    # environmental (storm, washout, river crossing) was dropped for v1 —
    # off-scene dex/hp-drain mechanics felt annoying without the rest of the
    # mechanical tier wired. Revisit later.
    module EncounterPolicy
      ENCOUNTER_RATE   = 0.25  # per-segment baseline; tunable
      COOLDOWN_MINUTES = 30    # game-time minutes after a fire before dice may roll again

      BUCKET_WEIGHTS = {
        "social"    => 0.0,
        "discovery" => 0.0,
        "combat"    => 1.0
      }.freeze

      # Returns true when the dice fires AND the journey isn't on cooldown.
      def self.fires?(journey:, current_game_time:, rng: Random.new)
        return false if current_game_time < (journey.cooldown_until_game_time || 0)
        rng.rand < ENCOUNTER_RATE
      end

      # Weighted-random pick from BUCKET_WEIGHTS. Returns one of the keys.
      def self.pick_bucket(rng: Random.new)
        total = BUCKET_WEIGHTS.values.sum
        roll  = rng.rand * total
        cumulative = 0.0
        BUCKET_WEIGHTS.each do |bucket, weight|
          cumulative += weight
          return bucket if roll < cumulative
        end
        BUCKET_WEIGHTS.keys.first  # fallback
      end
    end
  end
end
