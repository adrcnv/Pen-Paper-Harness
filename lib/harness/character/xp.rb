module Harness
  module Character
    # XP and level-up math.
    #
    # Threshold curve (cumulative XP to REACH level N): 50 × N × (N-1).
    #   level 1 → 0   (start state)
    #   level 2 → 100
    #   level 3 → 300
    #   level 4 → 600
    #   level 5 → 1000
    #   level 10 → 4500
    #   level 20 → 19000
    # Standard D&D-shape quadratic. Higher levels take longer to reach,
    # which compounds with the per-kill XP curve below.
    #
    # Per-kill XP (ELO-ish, without formal expected-score math): base
    # scales with victim level (a level-12 victim is intrinsically worth
    # more than a level-1 one), then a level-difference multiplier shifts
    # the result based on relative skill. Fighting up gives a bonus;
    # fighting down falls off fast so a level-10 player can't farm
    # level-1 commoners for progression.
    #
    # Auto-levelup: award! adds XP and loops levelup! until the character
    # is below the next threshold. Multi-level gains in one award are
    # supported (rare — would take killing something well above your
    # head). Each levelup bumps level, recomputes max_hp, restores
    # current_hp to new max, grants one new ability if eligible.
    module XP
      BASE_PER_VICTIM_LEVEL = 50

      class << self
        # Cumulative XP needed to BE at the given level. Level 1 = 0.
        def threshold_for(level)
          n = [ level.to_i, 1 ].max
          50 * n * (n - 1)
        end

        # XP for a successful NON-COMBAT check. Risk is priced by the DC
        # (trivial/easy pay nothing — mundane rolls can't be farmed for
        # progression); "clever" is priced by the SITUATIONAL roll_modifier
        # the caller already assigned for player tactical creativity (see
        # resolve's roll_modifier schema) — never by a fresh LLM judgment.
        # Opposed checks (no DC — beating a live opponent's roll) pay the
        # hard-tier rate.
        CHECK_XP = {
          "trivial" => 0, "easy" => 0, "moderate" => 5, "hard" => 15, "very_hard" => 30
        }.freeze
        OPPOSED_CHECK_XP       = 15
        CLEVER_BONUS_PER_POINT = 3

        def for_check(difficulty:, opposed: false, situational_modifier: 0)
          base = opposed ? OPPOSED_CHECK_XP : CHECK_XP.fetch(difficulty.to_s, 0)
          return 0 if base.zero?
          base + situational_modifier.to_i.clamp(0, 5) * CLEVER_BONUS_PER_POINT
        end

        # XP awarded for downing one character at victim_level when the
        # killer is at killer_level. Returns at least 1 (a kill is a kill;
        # symbolic XP for trivial fights so the counter still moves).
        def for_kill(killer_level:, victim_level:)
          k = killer_level.to_i
          v = victim_level.to_i
          base = BASE_PER_VICTIM_LEVEL * v
          mult = level_diff_multiplier(v - k)
          [ (base * mult).floor, 1 ].max
        end

        # Adds `amount` XP to character.xp, then auto-levels-up while the
        # new total clears the next-level threshold. Returns a hash
        # describing what happened:
        #   { gained:, total:, levels_gained:, new_level:, abilities_gained: }
        # `abilities_gained` is the array of ability rows added by the
        # levelups (may be empty if pool was exhausted).
        def award!(character, amount, rng: Random.new)
          gained = amount.to_i
          return null_award_result(character) if gained <= 0

          new_total = character.xp.to_i + gained
          character.update!(xp: new_total)

          levels_gained     = 0
          abilities_gained  = []

          # Loop: level up while threshold for (current_level + 1) is met.
          # Multi-level gains are rare but possible from a single huge kill.
          while new_total >= threshold_for(character.level + 1)
            result = levelup!(character, rng: rng)
            levels_gained    += 1
            abilities_gained += result[:abilities_gained]
          end

          {
            gained:           gained,
            total:            new_total,
            levels_gained:    levels_gained,
            new_level:        character.level,
            abilities_gained: abilities_gained,
            next_threshold:   threshold_for(character.level + 1)
          }
        end

        # Performs ONE levelup in place. Bumps level, recomputes max_hp,
        # restores current_hp to the new max (level-up restoration is the
        # one mechanical "your wounds are healed" moment outside of rest),
        # and grants one new ability:
        #   - Player rows: defers the pick by incrementing
        #     properties.pending_ability_picks. bin/play drains it via
        #     Abilities::Picker before the next input cycle. Returns
        #     abilities_gained=[] for player levelups (no immediate grant).
        #   - Npc rows: random pick from the eligible pool, in place
        #     (the existing auto-assignment behavior).
        def levelup!(character, rng: Random.new)
          character.update!(level: character.level + 1)
          ::Harness::Character::HP.apply!(character, reset_current: true)
          if character.is_a?(::Player)
            increment_pending_pick!(character)
            { abilities_gained: [] }
          else
            { abilities_gained: grant_one_ability!(character, rng: rng) }
          end
        end

        private

        # Multiplier table — fighting up rewards heavily, fighting down
        # falls off so XP-grinding low-level enemies stops being worth it.
        def level_diff_multiplier(diff)
          case diff
          when 5..Float::INFINITY then 2.0
          when 2..4               then 1.5
          when 0..1               then 1.0
          when -2..-1             then 0.5
          when -5..-3             then 0.25
          else                         0.1
          end
        end

        # Player level-ups defer ability selection. Stored on properties
        # so it survives across turns; Abilities::Picker.drain_pending! pulls
        # the counter back to zero at the next input cycle.
        def increment_pending_pick!(character)
          props = (character.properties || {}).dup
          props["pending_ability_picks"] = props["pending_ability_picks"].to_i + 1
          character.update!(properties: props)
        end

        # Grants one new ability the character doesn't already have, picked
        # from their class's eligible pool at the new level. Returns array
        # (1 element on success, 0 if pool is exhausted).
        def grant_one_ability!(character, rng:)
          current_ids = Array(character.abilities).map { |a| a["id"] }.compact
          eligible = ::Harness::Abilities::Library
                       .for_class(character.character_class, max_level: character.level)
                       .reject { |a| current_ids.include?(a["id"]) }
          return [] if eligible.empty?

          new_ability = eligible.sample(random: rng)
          # Stamp uses_remaining so the new ability can be used before next rest.
          stamped = new_ability.merge("uses_remaining" => new_ability["uses_per_rest"])
          character.update!(abilities: Array(character.abilities) + [ stamped ])
          [ stamped ]
        end

        def null_award_result(character)
          {
            gained:           0,
            total:            character.xp.to_i,
            levels_gained:    0,
            new_level:        character.level,
            abilities_gained: [],
            next_threshold:   threshold_for(character.level + 1)
          }
        end
      end
    end
  end
end
