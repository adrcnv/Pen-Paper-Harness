require "yaml"

module Harness
  module Items
    # Anchored-item seeding for locations. Mirrors the per-class
    # NPC inventory roller, but the items spawn anchored to a location
    # instead of an owner. Idempotent: each location seeds at most once
    # in its lifetime, gated on `properties.items_seeded`.
    #
    # Bucket selection (see location_seeder.yml for the tables):
    #   - wilderness_leaf with encounter_type=combat    → encounter_combat
    #   - wilderness_leaf with encounter_type=discovery → encounter_discovery
    #   - wilderness_leaf with encounter_type=social    → encounter_social
    #   - parent_id present                             → sublocation
    #   - top-level worldgen (parent_id nil + coords)   → city
    #   - everything else                               → no seeding (returns [])
    module LocationSeeder
      SEEDER_PATH = Rails.root.join("lib/harness/items/inventory/location_seeder.yml")

      class InvalidSeeder < StandardError; end

      class << self
        # Seed items at the location and mark it. Returns the created
        # Item rows (or [] for no-bucket / nothing-rolled / already-seeded).
        # Idempotent: a second call on the same location is a no-op.
        def seed!(location, rng: Random.new)
          return [] if location.nil?
          return [] if seeded?(location)

          bucket = bucket_for(location)
          return mark_and_return(location, []) unless bucket

          load!
          entry = @table[bucket]
          return mark_and_return(location, []) unless entry

          recipe_name = pick_roll(entry["rolls"], rng: rng)
          recipe      = entry["recipes"].fetch(recipe_name)
          items       = execute(recipe, location: location, rng: rng)

          mark_and_return(location, items)
        end

        # Pure helper for tests / callers that want to inspect bucket
        # selection without firing the side effects.
        def bucket_for(location)
          props = location.properties.is_a?(Hash) ? location.properties : {}
          if props["kind"] == "wilderness_leaf"
            etype = props["encounter_type"]
            return "encounter_#{etype}" if etype
            return nil
          end
          return "sublocation" if location.parent_id
          return "city"        if location.x.present? && location.y.present?
          nil
        end

        def seeded?(location)
          location.properties.is_a?(Hash) && location.properties["items_seeded"] == true
        end

        # Test seam — drops the cache so YAML changes are picked up.
        def reload!
          @table = nil
        end

        private

        def load!
          return if @table
          raise InvalidSeeder, "missing #{SEEDER_PATH}" unless SEEDER_PATH.exist?
          @table = YAML.safe_load_file(SEEDER_PATH, permitted_classes: [], aliases: false) || {}
          validate!
        end

        def validate!
          @table.each do |bucket, entry|
            unless entry.is_a?(Hash) && entry["rolls"].is_a?(Array) && entry["recipes"].is_a?(Hash)
              raise InvalidSeeder, "location_seeder[#{bucket}] must be a hash with `rolls` (array) and `recipes` (hash)"
            end
            entry["rolls"].each_with_index do |r, i|
              raise InvalidSeeder, "location_seeder[#{bucket}].rolls[#{i}]: missing name"                        unless r["name"].is_a?(String)
              raise InvalidSeeder, "location_seeder[#{bucket}].rolls[#{i}]: weight must be non-negative integer" unless r["weight"].is_a?(Integer) && r["weight"] >= 0
              raise InvalidSeeder, "location_seeder[#{bucket}].rolls[#{i}]: name=#{r['name']} not in recipes"    unless entry["recipes"].key?(r["name"])
            end
            entry["recipes"].each do |name, recipe|
              raise InvalidSeeder, "location_seeder[#{bucket}].recipes[#{name}] must be array" unless recipe.is_a?(Array)
              recipe.each_with_index { |item, i| validate_item!("location_seeder[#{bucket}].recipes[#{name}][#{i}]", item) }
            end
          end
        end

        def validate_item!(prefix, item)
          raise InvalidSeeder, "#{prefix}: must be a hash" unless item.is_a?(Hash)
          has_specific = item["specific"].is_a?(String)
          has_category = item["category"].is_a?(String)
          unless has_specific ^ has_category
            raise InvalidSeeder, "#{prefix}: must specify exactly one of `specific` or `category`"
          end
          if has_specific
            raise InvalidSeeder, "#{prefix}: specific=#{item['specific'].inspect} not in Library" unless ::Harness::Items::Library.find(item["specific"])
          else
            raise InvalidSeeder, "#{prefix}: category=#{item['category'].inspect} not in Library::CATEGORIES" unless ::Harness::Items::Library::CATEGORIES.include?(item["category"])
          end
          if (c = item["chance"])
            raise InvalidSeeder, "#{prefix}: chance must be in [0,1]" unless c.is_a?(Numeric) && c >= 0 && c <= 1
          end
        end

        def pick_roll(rolls, rng:)
          total  = rolls.sum { |r| r["weight"].to_i }
          target = rng.rand(total) + 1
          cum    = 0
          rolls.each do |r|
            cum += r["weight"].to_i
            return r["name"] if target <= cum
          end
          rolls.last["name"]
        end

        def execute(recipe, location:, rng:)
          recipe.filter_map { |item|
            next if item["chance"] && rng.rand >= item["chance"].to_f
            if item["specific"]
              ::Harness::Items::Generator.roll_specific(item["specific"], location: location, rng: rng)
            else
              ::Harness::Items::Generator.roll_from_category(item["category"], location: location, rng: rng)
            end
          }
        end

        def mark_and_return(location, items)
          props = (location.properties || {}).merge("items_seeded" => true)
          location.update!(properties: props)
          items
        end
      end
    end
  end
end
