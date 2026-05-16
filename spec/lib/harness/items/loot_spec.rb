require "rails_helper"

RSpec.describe Harness::Items::Loot do
  let(:loc)      { Location.create!(name: "Crypt") }
  let(:deceased) { Npc.create!(name: "Korr", location: loc, character_class: "fighter", coins: 12) }

  describe ".drop_to_floor" do
    it "detaches every item the deceased was carrying and anchors them to the location" do
      a = Item.create!(name: "rusty sword",  character_id: deceased.id, properties: { "tags" => [ "weapon" ] })
      b = Item.create!(name: "tarnished ring", character_id: deceased.id, properties: { "tags" => [ "jewelry" ] })

      result = described_class.drop_to_floor(deceased)
      expect(result.map(&:id).sort).to eq([ a.id, b.id ].sort)

      [ a, b ].each do |it|
        it.reload
        expect(it.character_id).to be_nil
        expect(it.location_id).to eq(loc.id)
      end
    end

    it "leaves coins on the deceased — coins are looted via transfer_coins, not as items" do
      Item.create!(name: "knife", character_id: deceased.id, properties: {})
      described_class.drop_to_floor(deceased)
      expect(deceased.reload.coins).to eq(12)
    end

    it "is a no-op when the deceased had no items" do
      expect(described_class.drop_to_floor(deceased)).to eq([])
    end

    it "is a no-op when the deceased has no location" do
      orphan = Npc.create!(name: "Wraith", location: nil, character_class: "commoner")
      Item.create!(name: "ghost knife", character_id: orphan.id, properties: {})
      expect(described_class.drop_to_floor(orphan)).to eq([])
    end

    it "is a no-op when passed nil" do
      expect(described_class.drop_to_floor(nil)).to eq([])
    end
  end
end
