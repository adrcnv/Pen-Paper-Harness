require "rails_helper"

RSpec.describe Location, type: :model do
  describe "residence predicates (home-assignment + eviction)" do
    it "treats a city (no kind) as a settlement and a residence" do
      city = Location.create!(name: "Osmere", x: 1.0, y: 1.0)
      expect(city.settlement?).to be(true)
      expect(city.lair?).to be(false)
      expect(city.residence?).to be(true)
    end

    it "treats a sublocation as a settlement and a residence" do
      city = Location.create!(name: "Osmere")
      tav  = Location.create!(name: "Tavern", parent_id: city.id, properties: { "kind" => "sublocation" })
      expect(tav.settlement?).to be(true)
      expect(tav.residence?).to be(true)
    end

    it "treats a combat encounter site as a lair (residence) but not a settlement" do
      lair = Location.create!(name: "Ambush Bend", properties: { "kind" => "wilderness_leaf", "encounter_type" => "combat" })
      expect(lair.settlement?).to be(false)
      expect(lair.lair?).to be(true)
      expect(lair.residence?).to be(true) # a bandit lives here → spawned NPCs get home == here
    end

    it "treats a discovery encounter site as a lair (the hermit lives there)" do
      refuge = Location.create!(name: "Old Shrine", properties: { "kind" => "wilderness_leaf", "encounter_type" => "discovery" })
      expect(refuge.lair?).to be(true)
      expect(refuge.residence?).to be(true)
    end

    it "treats a social waypoint as neither settlement nor residence (travelers pass through)" do
      crossing = Location.create!(name: "Crossing", properties: { "kind" => "wilderness_leaf", "encounter_type" => "social" })
      expect(crossing.settlement?).to be(false)
      expect(crossing.lair?).to be(false)
      expect(crossing.residence?).to be(false) # spawned NPCs stay homeless → evicted/culled
    end

    it "treats open wilderness (no encounter_type) as non-residence" do
      wild = Location.create!(name: "Blackwood", properties: { "kind" => "wilderness_leaf" })
      expect(wild.residence?).to be(false)
    end
  end
end
