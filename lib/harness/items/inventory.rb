require "yaml"

module Harness
  module Items
    # Class-conditioned inventory roller. Two YAMLs:
    #   player_starter.yml — deterministic kits for fresh players
    #   npc_inventory.yml  — fat-tailed roll tables for NPCs
    #
    # Both reference Items::Library by id (specific) or category. Validation
    # runs at boot against the Library, so a typo in a recipe aborts at
    # startup rather than at first spawn.
    #
    # Indexed by character_class. Hatchery is responsible for ensuring
    # character_class is set before calling either roll method (it is —
    # Stats::Materializer commits character_class before HP, abilities,
    # and inventory run).
    module Inventory
      INVENTORY_DIR = Rails.root.join("lib/harness/items/inventory")

      class InvalidInventory < StandardError; end

      class << self
        # Roll the deterministic player starter kit and create Item rows
        # owned by the player. Returns the array of created items. No-op
        # (returns []) if the player's class isn't in the starter table.
        def roll_for_player(character, rng: Random.new)
          load!
          klass = character.character_class.to_s
          entry = @player_starter[klass]
          return [] unless entry
          add_coins!(character, entry["coins"], rng: rng)
          execute(entry["items"] || [], owner: character, rng: rng)
        end

        # Roll ONLY the starter coins for a player, leaving any existing
        # items untouched. Used by the bin/play backfill for saves whose
        # items predate Phase 3 — items already exist, coins do not.
        # Caller decides whether to fire (typically: only when coins == 0).
        def roll_starter_coins!(character, rng: Random.new)
          load!
          entry = @player_starter[character.character_class.to_s]
          return 0 unless entry
          add_coins!(character, entry["coins"], rng: rng) || 0
        end

        # Roll an NPC's inventory: pick one named outcome from the rolls
        # table (weighted), execute the matching recipe. Returns created
        # Item rows. No-op if the class isn't in the inventory table.
        # Coin roll fires on every NPC regardless of which recipe wins —
        # an unarmed peasant still has loose change.
        def roll_for_npc(character, rng: Random.new)
          load!
          klass = character.character_class.to_s
          entry = @npc_inventory[klass]
          return [] unless entry
          add_coins!(character, entry["coins"], rng: rng)
          recipe_name = pick_roll(entry["rolls"], rng: rng)
          recipe      = entry["recipes"].fetch(recipe_name)
          execute(recipe, owner: character, rng: rng)
        end

        # Test seam — drops the cache so changes to the YAMLs are picked up.
        def reload!
          @player_starter = nil
          @npc_inventory  = nil
        end

        private

        def load!
          return if @player_starter && @npc_inventory
          ps_path = INVENTORY_DIR.join("player_starter.yml")
          ni_path = INVENTORY_DIR.join("npc_inventory.yml")
          raise InvalidInventory, "missing #{ps_path}" unless ps_path.exist?
          raise InvalidInventory, "missing #{ni_path}" unless ni_path.exist?
          @player_starter = YAML.safe_load_file(ps_path, permitted_classes: [], aliases: false) || {}
          @npc_inventory  = YAML.safe_load_file(ni_path, permitted_classes: [], aliases: false) || {}
          validate!
        end

        def validate!
          @player_starter.each do |klass, entry|
            unless entry.is_a?(Hash) && (entry["items"].nil? || entry["items"].is_a?(Array))
              raise InvalidInventory, "player_starter[#{klass}] must be a hash with optional `items` array and optional `coins` formula"
            end
            validate_dice_formula!("player_starter[#{klass}].coins", entry["coins"])
            (entry["items"] || []).each_with_index { |item, i| validate_item!("player_starter[#{klass}].items[#{i}]", item) }
          end
          @npc_inventory.each do |klass, entry|
            unless entry.is_a?(Hash) && entry["rolls"].is_a?(Array) && entry["recipes"].is_a?(Hash)
              raise InvalidInventory, "npc_inventory[#{klass}] must be a hash with `rolls` (array) and `recipes` (hash)"
            end
            validate_dice_formula!("npc_inventory[#{klass}].coins", entry["coins"])
            entry["rolls"].each_with_index do |r, i|
              raise InvalidInventory, "npc_inventory[#{klass}].rolls[#{i}]: missing name"                           unless r["name"].is_a?(String)
              raise InvalidInventory, "npc_inventory[#{klass}].rolls[#{i}]: weight must be non-negative integer"    unless r["weight"].is_a?(Integer) && r["weight"] >= 0
              raise InvalidInventory, "npc_inventory[#{klass}].rolls[#{i}]: name=#{r['name']} not in recipes"       unless entry["recipes"].key?(r["name"])
            end
            entry["recipes"].each do |name, recipe|
              raise InvalidInventory, "npc_inventory[#{klass}].recipes[#{name}] must be array" unless recipe.is_a?(Array)
              recipe.each_with_index { |item, i| validate_item!("npc_inventory[#{klass}].recipes[#{name}][#{i}]", item) }
            end
          end
        end

        def validate_dice_formula!(prefix, formula)
          return if formula.nil?
          raise InvalidInventory, "#{prefix}: must be a string formula" unless formula.is_a?(String)
          ::Harness::Abilities::DiceFormula.parse(formula)
        rescue ::Harness::Abilities::DiceFormula::ParseError => e
          raise InvalidInventory, "#{prefix}: #{e.message}"
        end

        def validate_item!(prefix, item)
          raise InvalidInventory, "#{prefix}: must be a hash" unless item.is_a?(Hash)
          has_specific = item["specific"].is_a?(String)
          has_category = item["category"].is_a?(String)
          unless has_specific ^ has_category
            raise InvalidInventory, "#{prefix}: must specify exactly one of `specific` or `category`"
          end
          if has_specific
            raise InvalidInventory, "#{prefix}: specific=#{item['specific'].inspect} not in Library" unless ::Harness::Items::Library.find(item["specific"])
          else
            raise InvalidInventory, "#{prefix}: category=#{item['category'].inspect} not in Library::CATEGORIES" unless ::Harness::Items::Library::CATEGORIES.include?(item["category"])
          end
          if (c = item["chance"])
            raise InvalidInventory, "#{prefix}: chance must be in [0,1]" unless c.is_a?(Numeric) && c >= 0 && c <= 1
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
          rolls.last["name"]  # defensive
        end

        def add_coins!(character, formula, rng:)
          return nil if formula.nil?
          amount = ::Harness::Abilities::DiceFormula.roll(formula, rng: rng)
          return 0 unless amount.positive?
          character.update!(coins: character.coins.to_i + amount)
          amount
        end

        def execute(recipe, owner:, rng:)
          recipe.filter_map { |item|
            next if item["chance"] && rng.rand >= item["chance"].to_f
            if item["specific"]
              ::Harness::Items::Generator.roll_specific(item["specific"], owner: owner, rng: rng)
            else
              ::Harness::Items::Generator.roll_from_category(item["category"], owner: owner, rng: rng)
            end
          }
        end
      end
    end
  end
end
