module Harness
  module Items
    # Aggregates an actor's owned-item modifiers for the resolver. Pure
    # Ruby, one DB query per call (cheap; resolves are infrequent).
    #
    # Two access patterns:
    #   - stat_bonus(actor, stat)  → integer to add to the actor's effective stat
    #   - bonus_damage(actor, on:) → integer rolled bonus damage from item dice
    #
    # The resolver doesn't need to know which item contributed what — that's
    # a narration concern (and currently narration doesn't lean on item
    # attribution beyond the explicit using_item_id arg).
    module Modifiers
      # Canonical equipment-gating vocabulary: the item tags an ability may
      # list in `requires_tags` to demand the actor be equipped for it. An item
      # supplies a tag via its `base_tags` (weapons carry "weapon", a shield
      # carries "shield", a focus/robe "magical_implement", etc). The gate
      # (has_required_tags?) is satisfied when the actor owns an item carrying
      # ALL required tags. This is the SINGLE source of truth the myths rework's
      # generated-ability path should draw from when emitting requires_tags —
      # so generated abilities and generated/stock items agree on the same
      # words rather than free-texting "spear" vs "polearm". Tag labels are all
      # we have; keep this list and item base_tags in lockstep.
      EQUIPMENT_TAGS = %w[
        weapon edged blunt polearm reach ranged two_handed light
        focus magical_implement
        armor medium heavy shield
      ].freeze

      class << self
        # Sum of `op: add` modifiers on `stat`, across all owned items — plus,
        # when the caller passes the clock (`now`), the character's live
        # spell-borne active_effects (same modifier shape, timed).
        def stat_bonus(actor, stat, now: nil)
          return 0 unless actor&.id
          base = modifiers_for(actor)
            .select { |m| m["stat"] == stat.to_s && m["op"] == "add" }
            .sum    { |m| m["value"].to_i }
          return base if now.nil?
          base + ::Harness::Character::ActiveEffects.active_for(actor, now: now)
            .flat_map { |e| Array(e["modifiers"]) }
            .select   { |m| m["stat"] == stat.to_s && m["op"] == "add" }
            .sum      { |m| m["value"].to_i }
        end

        # Roll all item damage_dice modifiers gated on a phase like "attack".
        # Each modifier was already chance-gated at instantiation time, so
        # presence here means it applies — just roll the dice.
        def bonus_damage(actor, on:, rng: Random.new)
          return 0 unless actor&.id
          modifiers_for(actor)
            .select { |m| m["damage_dice"] && m["op"] == "add" && m["on"].to_s == on.to_s }
            .sum    { |m| ::Harness::Abilities::DiceFormula.roll(m["damage_dice"], rng: rng) }
        end

        # Returns the union of all tag arrays across an actor's owned items.
        # Used for ability-tag gating: an ability that requires_tags = [weapon]
        # is usable if any owned item supplies that tag.
        def tags(actor)
          return [] unless actor&.id
          ::Item.where(character_id: actor.id).flat_map { |i|
            Array((i.properties || {})["tags"])
          }.uniq
        end

        # Does the actor's inventory satisfy a list of required tags?
        # An empty / nil requirement passes trivially.
        def has_required_tags?(actor, required_tags)
          return true  if required_tags.nil? || required_tags.empty?
          return false unless actor
          owned = tags(actor)
          required_tags.all? { |t| owned.include?(t) }
        end

        private

        def modifiers_for(character)
          ::Item.where(character_id: character.id).flat_map { |i|
            Array((i.properties || {})["modifiers"])
          }
        end
      end
    end
  end
end
