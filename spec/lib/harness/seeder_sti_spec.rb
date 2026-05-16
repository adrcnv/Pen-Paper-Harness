require "rails_helper"

RSpec.describe Harness::Seeder do
  let(:city) { Location.create!(name: "Saltmere") }

  describe "#npc" do
    it "creates an Npc row" do
      b = described_class.new
      npc = b.npc("Maren", subrole: "barkeep", location: city, personality: "stoic")
      expect(npc).to be_a(Npc)
      expect(npc.properties).to include("personality" => "stoic")
    end

    it "accepts stats and stores them on columns" do
      b = described_class.new
      npc = b.npc("Guard", subrole: "guard", location: city, strength: 15, dexterity: 12)
      expect(npc.strength).to eq(15)
      expect(npc.dexterity).to eq(12)
      expect(npc.properties).not_to have_key("strength")
    end
  end

  describe "#player" do
    it "creates a Player row" do
      b = described_class.new
      p = b.player("Hero", location: city, strength: 14, intelligence: 16)
      expect(p).to be_a(Player)
      expect(p.strength).to eq(14)
      expect(p.intelligence).to eq(16)
    end
  end

  describe "#character (legacy alias)" do
    it "creates an Npc (not a bare Character)" do
      b = described_class.new
      c = b.character("Maren", subrole: "barkeep", location: city)
      expect(c).to be_a(Npc)
      expect(c.type).to eq("Npc")
    end
  end
end
