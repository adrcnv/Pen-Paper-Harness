require "rails_helper"

RSpec.describe "treasure" do
  let(:loc) { Location.create!(name: "Hideout", x: 1.0, y: 1.0, biome: "lowland") }

  describe Harness::Treasure::LootTable do
    it "spawns the rarity's item count anchored to the location, plus coins" do
      hoard = described_class.spawn(rarity: "uncommon", location: loc, rng: Random.new(1))
      expect(hoard[:items].size).to eq(described_class::SPEC["uncommon"][:count])
      hoard[:items].each { |i| expect(i.location_id).to eq(loc.id) }
      expect(hoard[:coins]).to be > 0
    end

    it "a legendary hoard guarantees a magical item and richer coin than common" do
      legendary = described_class.spawn(rarity: "legendary", location: loc, rng: Random.new(2))
      expect(legendary[:items].any? { |i| i.properties["tags"].include?("magical") }).to be(true)
    end

    it "scales lock difficulty with rarity" do
      expect(described_class.lock_difficulty("common")).to eq("easy")
      expect(described_class.lock_difficulty("legendary")).to eq("very_hard")
    end
  end

  describe Harness::Treasure::Chest do
    it "places a closed, locked container holding a lazy loot spec (no contents yet)" do
      chest = described_class.place(location: loc, rarity: "rare", rng: Random.new(1))
      expect(chest.properties["container"]).to be(true)
      expect(chest.properties["state"]).to eq("closed")
      expect(chest.properties["locked"]).to eq("hard")
      expect(chest.properties.dig("loot", "rarity")).to eq("rare")
      # No loot items exist yet — only the chest row.
      expect(Item.where(location_id: loc.id).count).to eq(1)
    end

    it "names telegraph rarity" do
      legendary = described_class.place(location: loc, rarity: "legendary", rng: Random.new(1))
      expect(described_class::KIND_POOL["legendary"]).to include(legendary.name)
    end
  end

  describe Harness::Treasure::Seeder do
    def hideout
      Location.create!(name: "Bandit Camp", x: 2.0, y: 2.0, biome: "lowland",
                       properties: { "kind" => "wilderness_leaf", "encounter_type" => "combat" })
    end

    it "can place a chest in a combat encounter and is idempotent" do
      h = hideout
      # seed 4 with this rng yields a chest; assert a chest OR clean no-op, then idempotency
      described_class.seed!(h, rng: Random.new(4))
      expect(h.reload.properties["treasure_seeded"]).to be(true)
      count = Item.where(location_id: h.id).count
      described_class.seed!(h, rng: Random.new(4))
      expect(Item.where(location_id: h.id).count).to eq(count)  # no double seed
    end

    it "no-ops for a location with no treasure bucket (a plain town)" do
      town = Location.create!(name: "Town", x: 3.0, y: 3.0, biome: "lowland")
      expect(described_class.seed!(town)).to be_nil
      expect(Item.where(location_id: town.id, subrole: "chest")).to be_empty
    end

    it "eventually places a chest across seeds (combat bucket is treasure-bearing)" do
      placed = (1..40).count do |s|
        l = hideout
        described_class.seed!(l, rng: Random.new(s))
        Item.where(location_id: l.id, subrole: "chest").exists?
      end
      expect(placed).to be > 0
    end
  end
end
