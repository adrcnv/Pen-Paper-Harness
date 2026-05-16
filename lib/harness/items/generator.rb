module Harness
  module Items
    # Pure-Ruby item instantiation. Picks names from pools, rolls modifier
    # values from ranges, picks one effect from the effect_pool (for magical
    # items). Returns a saved Item row.
    #
    # No LLM. Generation is microseconds per spawn — that's the whole point
    # of moving items to YAML libraries.
    module Generator
      class << self
        # Roll a random item from a category and instantiate it.
        # Pass owner: <Character> to put it in their inventory, OR
        # location: <Location> to anchor it. Exactly one of the two.
        def roll_from_category(category, owner: nil, location: nil, rng: Random.new)
          template = Library.weighted_pick(category, rng: rng)
          return nil unless template
          instantiate(template, owner: owner, location: location, rng: rng)
        end

        # Instantiate by explicit library id (e.g., for player starter kits
        # where the class dictates a specific weapon kind).
        def roll_specific(id, owner: nil, location: nil, rng: Random.new)
          template = Library.find(id)
          return nil unless template
          instantiate(template, owner: owner, location: location, rng: rng)
        end

        # Pure templates → Item row. Public mainly for tests; callers
        # usually go through roll_from_category / roll_specific.
        def instantiate(template, owner: nil, location: nil, rng: Random.new)
          raise ArgumentError, "exactly one of owner: or location: required" if owner.nil? == location.nil?

          name      = roll_name(template, rng: rng)
          modifiers = roll_modifiers(template["modifier_table"], rng: rng)
          effects   = roll_effects(template["effect_pool"],      rng: rng)

          properties = {
            "tags"      => template["base_tags"].dup,
            "modifiers" => modifiers,
            "effects"   => effects
          }
          # Magical items with an auto_succeed_check (or any one-shot effect)
          # need their own use-counter — separate from per-rest ability uses.
          # Default to 1; YAML can override later if we want multi-use items.
          if effects.any? { |e| e["trigger"] == "auto_succeed_check" }
            properties["trigger_uses_remaining"] = 1
          end

          attrs = {
            name:       name,
            subrole:    template["id"],
            properties: properties
          }
          attrs[:character_id] = owner.id    if owner
          attrs[:location_id]  = location.id if location

          ::Item.create!(attrs)
        end

        private

        def roll_name(template, rng:)
          kind   = template["kind_pool"].sample(random: rng)
          flavor = template["flavor_pool"].sample(random: rng)
          flavor && !flavor.empty? ? "#{flavor} #{kind}" : kind
        end

        def roll_modifiers(table, rng:)
          return [] if table.nil? || table.empty?
          table.filter_map { |m|
            # `chance` gates whether the modifier applies at all (e.g. 30%
            # bonus die). Default 1.0 (always applies).
            next if m["chance"] && rng.rand >= m["chance"].to_f

            out = m.dup
            if (range = m["range"])
              out["value"] = rng.rand(range[0]..range[1])
              out.delete("range")
            end
            out["chance"] && out.delete("chance")  # don't carry probability through to the row
            out
          }
        end

        def roll_effects(pool, rng:)
          return [] if pool.nil? || pool.empty?
          total  = pool.sum { |e| e["weight"].to_i }
          target = rng.rand(total) + 1
          cum    = 0
          pool.each do |e|
            cum += e["weight"].to_i
            return [ { "trigger" => e["trigger"], "params" => e["params"] || {} } ] if target <= cum
          end
          []  # unreachable
        end
      end
    end
  end
end
