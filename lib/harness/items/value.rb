module Harness
  module Items
    # Mechanical gold valuation of an item, computed on demand from its actual
    # rolled POWER — never its name. This preserves the DF "names decoupled from
    # power" mystery: a "rusted dagger" that rolled +2 STR is worth more than a
    # "gleaming dagger" that rolled +0. Coins are integers, so value is too.
    #
    # Nothing is stored; value is a pure function of the item's tags + modifiers
    # + effects, so shop prices stay stable across queries without a column.
    module Value
      BASE = 5

      # A small floor by item class so a plain (no-modifier) weapon/armor still
      # has a sensible worth. Picks the richest matching tag.
      CATEGORY_BASE = { "jewelry" => 14, "armor" => 10, "weapon" => 8 }.freeze

      STAT_PER_POINT   = 7    # each +1 to a stat modifier
      DAMAGE_MODIFIER  = 12   # each bonus damage-die modifier
      EFFECT_BONUS     = 45   # each triggered effect (rare/powerful)

      module_function

      def of(item)
        props = item.properties.is_a?(Hash) ? item.properties : {}
        tags  = Array(props["tags"])

        total  = BASE + category_base(tags)
        total += modifier_value(props["modifiers"])
        total += Array(props["effects"]).size * EFFECT_BONUS
        [ total.round, 1 ].max
      end

      def category_base(tags)
        CATEGORY_BASE.select { |tag, _| tags.include?(tag) }.values.max || 0
      end

      def modifier_value(modifiers)
        Array(modifiers).sum do |m|
          if m["damage_dice"]
            DAMAGE_MODIFIER
          else
            m["value"].to_i * STAT_PER_POINT
          end
        end
      end
    end
  end
end
