module Harness
  module Treasure
    # The rarity ladder. Maps a rarity tier to what a hoard of that tier yields,
    # and SPAWNS it (real Item rows + a coin amount) at open time — lazily, like
    # ShopStock, so the contents don't sit visible in the scene before the chest
    # is cracked. Pure mechanical; the LLM never decides what's inside.
    module LootTable
      RARITIES = %w[common uncommon rare legendary].freeze

      # count          — item rows generated
      # categories     — Items::Library categories rolled from for the mundane slots
      # magical_chance — per-slot chance the slot rolls from `magical` instead
      # coins          — DiceFormula string
      SPEC = {
        "common"    => { count: 1, categories: %w[weapons armor],         magical_chance: 0.0, coins: "2d10" },
        "uncommon"  => { count: 2, categories: %w[weapons armor jewelry], magical_chance: 0.15, coins: "3d12" },
        "rare"      => { count: 2, categories: %w[weapons armor jewelry], magical_chance: 0.5, coins: "5d20" },
        "legendary" => { count: 3, categories: %w[weapons armor jewelry], magical_chance: 1.0, coins: "4d20+60" }
      }.freeze

      # Lock toughness scales with rarity — a legendary hoard is harder to crack.
      LOCK_DIFFICULTY = {
        "common" => "easy", "uncommon" => "moderate", "rare" => "hard", "legendary" => "very_hard"
      }.freeze

      module_function

      def lock_difficulty(rarity)
        LOCK_DIFFICULTY.fetch(rarity.to_s, "moderate")
      end

      # Spawn the hoard at `location`. Returns { items: [Item...], coins: Integer }.
      def spawn(rarity:, location:, rng: Random.new)
        spec  = SPEC.fetch(rarity.to_s, SPEC["common"])
        items = Array.new(spec[:count]).map do
          category = (rng.rand < spec[:magical_chance]) ? "magical" : spec[:categories].sample(random: rng)
          ::Harness::Items::Generator.roll_from_category(category, location: location, rng: rng)
        end
        coins = ::Harness::Abilities::DiceFormula.roll(spec[:coins], rng: rng)
        { items: items, coins: coins }
      end
    end
  end
end
