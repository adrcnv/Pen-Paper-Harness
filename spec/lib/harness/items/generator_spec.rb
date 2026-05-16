require "rails_helper"

RSpec.describe Harness::Items::Generator do
  let(:loc)   { Location.create!(name: "Forge") }
  let(:owner) { Npc.create!(name: "Smith", location: loc, character_class: "fighter", level: 3) }

  describe ".roll_from_category" do
    it "creates an Item owned by the character with name + tags + modifiers" do
      item = described_class.roll_from_category("weapons", owner: owner, rng: Random.new(42))
      expect(item).to be_persisted
      expect(item.character_id).to eq(owner.id)
      expect(item.location_id).to be_nil
      expect(item.properties["tags"]).to include("weapon")
      expect(item.properties["modifiers"]).to be_an(Array)
    end

    it "creates an Item anchored to a location when location: is passed" do
      item = described_class.roll_from_category("armor", location: loc, rng: Random.new(7))
      expect(item.location_id).to eq(loc.id)
      expect(item.character_id).to be_nil
    end

    it "raises when neither owner nor location is provided" do
      expect {
        described_class.roll_from_category("weapons")
      }.to raise_error(ArgumentError, /exactly one of owner: or location:/)
    end
  end

  describe ".roll_specific" do
    it "instantiates a known library entry by id" do
      item = described_class.roll_specific("longblade", owner: owner, rng: Random.new(1))
      expect(item.subrole).to eq("longblade")  # subrole carries the template id
      expect(item.properties["tags"]).to include("weapon", "edged", "two_handed")
    end

    it "returns nil for unknown ids" do
      expect(described_class.roll_specific("zillithrax", owner: owner)).to be_nil
    end
  end

  describe "modifier rolling" do
    it "rolls a stat value from the range — different seeds produce different values" do
      values = (1..50).map { |seed|
        item = described_class.roll_specific("longblade", owner: owner, rng: Random.new(seed))
        item.properties["modifiers"].select { |m| m["stat"] == "strength" }.sum { |m| m["value"].to_i }
      }
      expect(values.uniq.size).to be > 1, "expected variability across seeds; got #{values.uniq.inspect}"
      expect(values.min).to be >= 0
      expect(values.max).to be <= 3
    end

    it "chance-gated modifiers may or may not be present" do
      with_bonus = (1..200).map { |seed|
        item = described_class.roll_specific("longblade", owner: owner, rng: Random.new(seed))
        item.properties["modifiers"].any? { |m| m["damage_dice"] }
      }
      expect(with_bonus).to include(true).and include(false)
    end
  end

  describe "magical effect rolling" do
    it "every magical instance has exactly one effect" do
      20.times do |seed|
        item = described_class.roll_specific("protective_amulet", owner: owner, rng: Random.new(seed))
        expect(item.properties["effects"].size).to eq(1)
        expect(Harness::Items::TriggerRegistry.known?(item.properties["effects"].first["trigger"])).to be(true)
      end
    end

    it "rolls different effects across seeds" do
      triggers = (1..50).map { |seed|
        described_class.roll_specific("protective_amulet", owner: owner, rng: Random.new(seed))
                       .properties["effects"].first["trigger"]
      }
      expect(triggers.uniq.size).to be > 1
    end

    it "auto_succeed_check items get a trigger_uses_remaining counter" do
      item = nil
      40.times do |seed|
        candidate = described_class.roll_specific("keepsake", owner: owner, rng: Random.new(seed))
        if candidate.properties["effects"].first["trigger"] == "auto_succeed_check"
          item = candidate
          break
        end
      end
      skip "no auto_succeed roll in 40 seeds (rare; rerun)" if item.nil?
      expect(item.properties["trigger_uses_remaining"]).to eq(1)
    end
  end
end
