module Harness
  module Abilities
    # Parses + rolls dice formula strings used by the ability library.
    # Supports terms of the shape `NdM` (N dice of M sides), `+K` flat
    # bonus, and additive composition (`1d8+1d4`, `2d6+3`, `1d10`).
    # Subtraction and parentheses are not supported — keep the surface
    # tight so authoring stays unambiguous.
    #
    # Roll model: caster_level - min_level adds `damage_per_level` worth
    # of dice on top of the base. So Incineration Blast min_level=7,
    # damage_dice="2d6+2d4", damage_per_level="1d6":
    #   level 7  -> roll 2d6+2d4
    #   level 8  -> roll 2d6+2d4 + 1d6
    #   level 12 -> roll 2d6+2d4 + 5d6
    #
    # Result is an integer. RNG is injectable for tests.
    module DiceFormula
      Term = Struct.new(:count, :sides, :flat, keyword_init: true)

      class ParseError < StandardError; end

      class << self
        # Roll an ability's damage at a given caster level.
        def roll_ability(ability:, caster_level:, rng: Random.new)
          base = ability["damage_dice"]
          per  = ability["damage_per_level"]
          min  = ability["min_level"].to_i

          total = 0
          total += roll(base, rng: rng) if base.is_a?(String) && !base.strip.empty?

          if per.is_a?(String) && !per.strip.empty?
            level_steps = [ caster_level.to_i - min, 0 ].max
            level_steps.times { total += roll(per, rng: rng) }
          end

          total
        end

        # Public for tests: roll a single formula string.
        def roll(formula, rng: Random.new)
          parse(formula).sum { |term| roll_term(term, rng: rng) }
        end

        # Public for tests: parse a formula into Term structs.
        def parse(formula)
          formula.to_s.split("+").map(&:strip).reject(&:empty?).map do |chunk|
            if (m = chunk.match(/\A(\d+)d(\d+)\z/))
              Term.new(count: m[1].to_i, sides: m[2].to_i, flat: 0)
            elsif (m = chunk.match(/\A(\d+)\z/))
              Term.new(count: 0, sides: 0, flat: m[1].to_i)
            else
              raise ParseError, "cannot parse formula chunk: #{chunk.inspect} (in #{formula.inspect})"
            end
          end
        end

        private

        def roll_term(term, rng:)
          if term.count.positive? && term.sides.positive?
            term.count.times.sum { rng.rand(1..term.sides) }
          else
            term.flat
          end
        end
      end
    end
  end
end
