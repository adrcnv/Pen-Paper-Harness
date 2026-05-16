require "rails_helper"

RSpec.describe Harness::Scene::Assembler do
  let(:city) { Location.create!(name: "Saltmere", description: "harbor") }

  describe ".for" do
    it "returns a Snapshot struct with the given location" do
      snap = described_class.for(location: city)
      expect(snap).to be_a(Harness::Scene::Snapshot)
      expect(snap.location).to eq(city)
    end

    # Path-edge adjacency was retired with the Path model. Inter-location
    # movement is `transition` (sibling/parent/child) or `travel` (top-level
    # coords → coords). Snapshot no longer carries an `adjacent` field.

    describe "present_characters" do
      let(:tavern)    { Location.create!(name: "Dockside Inn", parent: city) }
      let(:warehouse) { Location.create!(name: "Warehouse",    parent: city) }

      it "includes characters at this location" do
        maren = Npc.create!(name: "Maren", location: tavern)
        snap = described_class.for(location: tavern)
        expect(snap.present_characters).to include(maren)
      end

      it "EXCLUDES characters at sibling locations (the brewer at the brewery is not at the tavern)" do
        joey      = Npc.create!(name: "Joey",      location: tavern)
        brewer    = Npc.create!(name: "Brewer",    location: warehouse)
        snap = described_class.for(location: tavern)
        expect(snap.present_characters).to contain_exactly(joey)
        expect(snap.present_characters).not_to include(brewer)
      end

      it "excludes characters at the parent city (city-level NPCs aren't inside the tavern)" do
        city_guard = Npc.create!(name: "City Guard", location: city)
        snap = described_class.for(location: tavern)
        expect(snap.present_characters).not_to include(city_guard)
      end

      it "excludes characters at a different parent (another city)" do
        other_city    = Location.create!(name: "Ironwood")
        other_tavern  = Location.create!(name: "Greenleaf", parent: other_city)
        stranger      = Npc.create!(name: "Stranger", location: other_tavern)
        snap = described_class.for(location: tavern)
        expect(snap.present_characters).not_to include(stranger)
      end

      it "uses only-this-location when the location has no parent" do
        wilderness = Location.create!(name: "Bandit Cave") # no parent
        bandit  = Npc.create!(name: "Bandit",  location: wilderness)
        outsider = Npc.create!(name: "Outsider", location: city)
        snap = described_class.for(location: wilderness)
        expect(snap.present_characters).to contain_exactly(bandit)
      end

      it "returns an empty array when nobody is around" do
        snap = described_class.for(location: tavern)
        expect(snap.present_characters).to eq([])
      end
    end

    describe "present_items" do
      let(:tavern)    { Location.create!(name: "Dockside Inn", parent: city) }
      let(:warehouse) { Location.create!(name: "Warehouse",    parent: city) }

      it "includes items anchored to this exact location" do
        mug = Item.create!(name: "Mug", location: tavern)
        snap = described_class.for(location: tavern)
        expect(snap.present_items).to include(mug)
      end

      it "excludes items at sibling locations (items stay put, unlike characters)" do
        crate = Item.create!(name: "Crate", location: warehouse)
        snap = described_class.for(location: tavern)
        expect(snap.present_items).not_to include(crate)
      end

      it "excludes items owned by a character (they're in inventory, not on the floor)" do
        maren = Npc.create!(name: "Maren", location: tavern)
        ledger  = Item.create!(name: "Ledger", character: maren)
        snap = described_class.for(location: tavern)
        expect(snap.present_items).not_to include(ledger)
      end
    end
  end
end
