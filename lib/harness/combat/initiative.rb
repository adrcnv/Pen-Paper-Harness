module Harness
  module Combat
    # Initiative roll: 1d20 + DEX_mod per combatant, descending order.
    # Stored once per fight (no re-rolls between rounds, per design).
    # Ties are broken by character_id (stable).
    module Initiative
      def self.roll(character_ids, rng: Random.new)
        scored = character_ids.map do |id|
          char = ::Character.find(id)
          score = rng.rand(1..20) + ::Harness::Dice.stat_mod(char.stat(:dexterity))
          [ id.to_i, score ]
        end
        scored.sort_by { |id, score| [ -score, id ] }.map(&:first)
      end
    end
  end
end
