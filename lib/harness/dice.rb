module Harness
  # Placeholder dice engine. D&D-adjacent — d20 + stat modifier vs either a
  # fixed DC (unopposed check) or the target's d20 + target_stat modifier
  # (opposed). Public-domain conventions only; swap for a real ruleset later.
  #
  # Callers pass integer stat values — all lookup, materialization, and
  # defaulting happen upstream in the resolve tool.
  #
  # Rng is injectable for deterministic tests.
  module Dice
    DC_TABLE = {
      "trivial"   => 5,
      "easy"      => 10,
      "moderate"  => 15,
      "hard"      => 20,
      "very_hard" => 25
    }.freeze

    VALID_DIFFICULTIES = DC_TABLE.keys.freeze

    Outcome = Struct.new(:result, :margin, :critical, :roll, :against, keyword_init: true)

    def self.check(actor_stat:, target_stat: nil, difficulty: "moderate", roll_modifier: 0, rng: Random.new)
      actor_roll  = rng.rand(1..20)
      actor_total = actor_roll + stat_mod(actor_stat) + roll_modifier.to_i

      if target_stat
        target_roll  = rng.rand(1..20)
        target_total = target_roll + stat_mod(target_stat)
        succeeded = actor_total > target_total   # tie defends
        diff      = actor_total - target_total
        against   = target_total
      else
        dc        = DC_TABLE.fetch(difficulty.to_s, 15)
        succeeded = actor_total >= dc            # meet-or-beat
        diff      = actor_total - dc
        against   = dc
      end

      build_outcome(actor_roll, succeeded, diff, actor_total, against)
    end

    # D&D 5e convention: modifier = (score - 10) / 2, rounded toward -infinity.
    # Ruby integer division does this natively for negatives.
    def self.stat_mod(stat_value)
      (stat_value.to_i - 10) / 2
    end

    def self.build_outcome(raw_roll, succeeded, diff, roll = nil, against = nil)
      if raw_roll == 20
        Outcome.new(result: "critical_success", margin: "decisive", critical: true, roll: roll, against: against)
      elsif raw_roll == 1
        Outcome.new(result: "critical_failure", margin: "decisive", critical: true, roll: roll, against: against)
      elsif succeeded
        Outcome.new(result: "success", margin: margin_for(diff.abs), critical: false, roll: roll, against: against)
      else
        Outcome.new(result: "failure", margin: margin_for(diff.abs), critical: false, roll: roll, against: against)
      end
    end

    def self.margin_for(absolute_diff)
      if absolute_diff >= 10
        "decisive"
      elsif absolute_diff >= 5
        "clear"
      else
        "narrow"
      end
    end
  end
end
