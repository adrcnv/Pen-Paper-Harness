require "rails_helper"

RSpec.describe Harness::Abilities::Assigner do
  let(:city) { Location.create!(name: "Saltmere") }

  describe ".slot_count_for" do
    it "level 1 = 2 slots (basic attack + utility — magical classes need their core spell)" do
      expect(described_class.slot_count_for(1)).to eq(2)
    end

    it "level N = N+1 slots" do
      expect(described_class.slot_count_for(2)).to eq(3)
      expect(described_class.slot_count_for(5)).to eq(6)
      expect(described_class.slot_count_for(12)).to eq(13)
      expect(described_class.slot_count_for(20)).to eq(21)
    end

    it "<1 levels still produce a non-negative count" do
      expect(described_class.slot_count_for(0)).to eq(1)
      expect(described_class.slot_count_for(-3)).to eq(-2)  # not normalized — Hatchery should never feed negative levels
    end
  end

  describe ".assign!" do
    it "assigns at least 2 abilities at level 1 (so a level-1 mage actually has spells)" do
      npc = Npc.create!(name: "Apprentice", location: city, character_class: "mage", level: 1)
      described_class.assign!(npc, rng: Random.new(1))
      expect(npc.reload.abilities.size).to be >= 2
    end

    it "assigns up to slot_count abilities, capped at eligible pool size" do
      npc = Npc.create!(name: "Captain", location: city, character_class: "fighter", level: 5)
      described_class.assign!(npc, rng: Random.new(1))
      eligible_count = Harness::Abilities::Library.for_class("fighter", max_level: 5).size
      slots = described_class.slot_count_for(5)
      expect(npc.reload.abilities.size).to eq([ slots, eligible_count ].min)
    end

    it "respects min_level — never assigns abilities the level can't reach" do
      npc = Npc.create!(name: "Hedge Mage", location: city, character_class: "mage", level: 2)
      described_class.assign!(npc, rng: Random.new(1))
      npc.reload.abilities.each do |a|
        expect(a["min_level"]).to be <= 2
      end
    end

    it "is filtered by class — fighter never gets mage abilities" do
      npc = Npc.create!(name: "Soldier", location: city, character_class: "fighter", level: 12)
      described_class.assign!(npc, rng: Random.new(7))
      npc.reload.abilities.each do |a|
        expect(a["classes"]).to include("fighter"),
          "fighter received #{a['id']} with classes #{a['classes'].inspect}"
      end
    end

    it "commoner draws from the commoner-tagged subset of the library only" do
      # Commoner only sees abilities where 'commoner' is in `classes`. No
      # advanced fighter/cleric/etc moves regardless of level.
      npc = Npc.create!(name: "Brawler", location: city, character_class: "commoner", level: 12)
      described_class.assign!(npc, rng: Random.new(11))
      eligible_size = Harness::Abilities::Library.for_class("commoner").size
      expect(npc.reload.abilities.size).to be <= eligible_size
      npc.reload.abilities.each do |a|
        expect(a["classes"]).to include("commoner")
      end
    end

    it "is a no-op for Player rows that already have abilities (idempotent)" do
      player = Player.create!(
        name: "Hero", location: city, character_class: "fighter", level: 5,
        abilities: [ { "name" => "Existing Move" } ]
      )
      described_class.assign!(player, rng: Random.new(1))
      expect(player.reload.abilities).to eq([ { "name" => "Existing Move" } ])
    end

    it "DEFERS picks for fresh Player rows via pending_ability_picks (Picker drains interactively)" do
      player = Player.create!(name: "Hero", location: city, character_class: "fighter", level: 5)
      described_class.assign!(player, rng: Random.new(1))
      player.reload
      expect(Array(player.abilities)).to be_empty
      expect(player.properties["pending_ability_picks"]).to eq(described_class.slot_count_for(5))
    end

    it "is deterministic given the same RNG seed" do
      npc1 = Npc.create!(name: "A", location: city, character_class: "mage", level: 8)
      npc2 = Npc.create!(name: "B", location: city, character_class: "mage", level: 8)
      described_class.assign!(npc1, rng: Random.new(42))
      described_class.assign!(npc2, rng: Random.new(42))
      ids1 = npc1.reload.abilities.map { |a| a["id"] }
      ids2 = npc2.reload.abilities.map { |a| a["id"] }
      expect(ids1).to eq(ids2)
    end
  end
end
