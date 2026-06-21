module Harness
  module Treasure
    # A chest is the VESSEL for treasure — a container Item anchored to a
    # location, holding a lazy loot spec (rarity) cracked open via OpenContainer.
    # It exists because the LLM won't place a hoard on its own any more than it
    # runs a shop: treasure is placed by structure, then dressed in narration.
    #
    # The chest's APPEARANCE telegraphs its rarity (a battered trunk vs a jewelled
    # casket) — fair warning without revealing the contents. Mechanical naming,
    # no LLM.
    module Chest
      # Per-rarity kind pools — the look hints at the worth.
      KIND_POOL = {
        "common"    => [ "wooden chest", "battered trunk", "plain coffer", "rough strongbox" ],
        "uncommon"  => [ "iron-banded chest", "oak strongbox", "traveler's lockbox", "studded coffer" ],
        "rare"      => [ "ornate chest", "brass-bound coffer", "merchant's strongbox", "lacquered casket" ],
        "legendary" => [ "ancient reliquary", "sealed sarcophagus", "jewelled casket", "rune-graven chest" ]
      }.freeze

      module_function

      # Create a closed, locked chest at `location` holding a `rarity` hoard.
      def place(location:, rarity: "common", rng: Random.new)
        name = (KIND_POOL[rarity.to_s] || KIND_POOL["common"]).sample(random: rng)
        ::Item.create!(
          name:       name,
          subrole:    "chest",
          location:   location,
          properties: {
            "container" => true,
            "state"     => "closed",
            "locked"    => LootTable.lock_difficulty(rarity),   # a difficulty tier; false = unlocked
            "loot"      => { "rarity" => rarity.to_s }            # consumed on open
          }
        )
      end

      def container?(item)
        item.properties.is_a?(Hash) && item.properties["container"] == true
      end
    end
  end
end
