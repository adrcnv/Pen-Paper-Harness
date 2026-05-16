module Harness
  module Character
    # HP computation. D&D-shape with one local divergence: the level-1
    # baseline includes the full CON SCORE (not just the mod). This is a
    # flat bump that persists at every level — the slope (per-level gain)
    # is the standard `die_avg + con_mod`, the intercept is what shifted
    # up. Reason: pure D&D level-1 is brutally fragile (a level-1 fighter
    # with CON 12 has 11 HP; a single 1d4 swing chunks 25%). The CON-score
    # baseline puts an L1 fighter around 22-25 HP, an L1 commoner around
    # 14-18 — survivable without flattening the leveling curve.
    #
    # Example: a level-5 fighter (1d10 hit die) with CON 14:
    #   max_hp = 10 + 14 + ceil(5.5) × 4 + 2 × 5
    #          = 10 + 14 + 24 + 10
    #          = 58
    #
    # A level-1 commoner with CON 10:
    #   max_hp = 6 + 10 + 0 + 0 = 16
    #
    # Level 0 returns 0; useful for characters that haven't been materialized.
    # CON modifier follows Dice.stat_mod ((stat - 10) / 2 floored).
    module HP
      class << self
        def compute_max(character_class:, level:, constitution:)
          return 0 if level.to_i < 1
          die_size = ::Harness::Abilities::Library.hit_die(character_class)
          die_avg  = ((die_size + 1) / 2.0).ceil
          con_mod  = ::Harness::Dice.stat_mod(constitution.to_i)

          die_size + constitution.to_i + (die_avg * (level.to_i - 1)) + (con_mod * level.to_i)
        end

        # Idempotent: re-running this on a character with current_hp set
        # leaves current_hp unchanged unless you opt into reset. Used by
        # Hatchery (fresh creation, sets both) and Levelup later (bumps
        # max, leaves current).
        def apply!(character, reset_current: true)
          max = compute_max(
            character_class: character.character_class,
            level:           character.level,
            constitution:    character.constitution
          )
          attrs = { max_hp: max }
          attrs[:current_hp] = max if reset_current
          character.update!(attrs)
          character
        end
      end
    end
  end
end
