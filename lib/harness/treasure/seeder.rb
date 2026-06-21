module Harness
  module Treasure
    # Places chests in the locations that warrant them, on first scene entry.
    # The LLM won't put a hoard in a bandit camp on its own, so structure does:
    # combat encounters (the bandits' takings) and discovery sites (a buried
    # cache, an old reliquary) roll for a chest at a weighted rarity. Idempotent
    # via `properties["treasure_seeded"]`. Pure mechanical.
    #
    # This is ADDITIVE to Items::LocationSeeder's scattered floor-loot — a
    # hideout can have loose gear AND a locked strongbox (the real prize).
    # Adventure sites (crypts/ruins, when built) place chests explicitly rather
    # than relying on this bucket roll.
    module Seeder
      # bucket => weighted [rarity|nil]. nil = no chest this time.
      TABLE = {
        "encounter_combat" => [
          [ nil,         35 ], [ "common",    45 ], [ "uncommon", 18 ], [ "rare", 2 ]
        ],
        "encounter_discovery" => [
          [ nil,         50 ], [ "common",    24 ], [ "uncommon", 18 ], [ "rare", 7 ], [ "legendary", 1 ]
        ]
      }.freeze

      module_function

      # Returns the chest Item created, or nil (no bucket / no chest rolled /
      # already seeded).
      def seed!(location, rng: Random.new, logger: Rails.logger)
        return nil if location.nil?
        return nil if seeded?(location)

        bucket = ::Harness::Items::LocationSeeder.bucket_for(location)
        weights = TABLE[bucket]
        return mark(location) { nil } unless weights

        rarity = weighted_pick(weights, rng)
        mark(location) do
          next nil if rarity.nil?
          chest = Chest.place(location: location, rarity: rarity, rng: rng)
          logger.info { "[Treasure::Seeder] #{location.name}: placed #{rarity} #{chest.name}" }
          chest
        end
      rescue StandardError => e
        logger.warn { "[Treasure::Seeder] failed for #{location&.name}: #{e.class}: #{e.message}" }
        nil
      end

      def seeded?(location)
        location.properties.is_a?(Hash) && location.properties["treasure_seeded"] == true
      end

      def weighted_pick(weights, rng)
        total  = weights.sum { |_, w| w }
        target = rng.rand(total) + 1
        cum = 0
        weights.each do |value, w|
          cum += w
          return value if target <= cum
        end
        weights.last.first
      end

      # Mark seeded (idempotent) and return whatever the block yields.
      def mark(location)
        result = yield
        props = (location.properties.is_a?(Hash) ? location.properties : {}).dup
        props["treasure_seeded"] = true
        location.update!(properties: props)
        result
      end
    end
  end
end
