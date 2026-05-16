require "rails_helper"

RSpec.describe Harness::Items::Modifiers do
  let(:loc)   { Location.create!(name: "Yard") }
  let(:actor) { Npc.create!(name: "Korr", location: loc, character_class: "fighter", level: 3, strength: 12) }

  def equip(actor, properties)
    Item.create!(name: "Trinket", character_id: actor.id, properties: properties)
  end

  describe ".stat_bonus" do
    it "is 0 when actor has no items" do
      expect(described_class.stat_bonus(actor, "strength")).to eq(0)
    end

    it "sums stat-add modifiers across items" do
      equip(actor, "modifiers" => [ { "stat" => "strength", "op" => "add", "value" => 1 } ])
      equip(actor, "modifiers" => [ { "stat" => "strength", "op" => "add", "value" => 2 } ])
      equip(actor, "modifiers" => [ { "stat" => "dexterity", "op" => "add", "value" => 1 } ])
      expect(described_class.stat_bonus(actor, "strength")).to eq(3)
      expect(described_class.stat_bonus(actor, "dexterity")).to eq(1)
      expect(described_class.stat_bonus(actor, "wisdom")).to eq(0)
    end

    it "ignores modifiers with op != add (Phase 1 supports add only)" do
      equip(actor, "modifiers" => [ { "stat" => "strength", "op" => "multiply", "value" => 2 } ])
      expect(described_class.stat_bonus(actor, "strength")).to eq(0)
    end
  end

  describe ".bonus_damage" do
    it "rolls each damage_dice modifier matched on the phase" do
      equip(actor, "modifiers" => [ { "damage_dice" => "1d4", "op" => "add", "on" => "attack" } ])
      equip(actor, "modifiers" => [ { "damage_dice" => "1d6", "op" => "add", "on" => "attack" } ])
      equip(actor, "modifiers" => [ { "damage_dice" => "1d4", "op" => "add", "on" => "defense" } ])

      total = described_class.bonus_damage(actor, on: "attack", rng: Random.new(1))
      expect(total).to be_between(2, 10)  # 1d4 + 1d6 lives in [2, 10]
    end

    it "is 0 when no items contribute" do
      expect(described_class.bonus_damage(actor, on: "attack")).to eq(0)
    end
  end

  describe ".has_required_tags?" do
    it "trivially passes for empty / nil requirements" do
      expect(described_class.has_required_tags?(actor, [])).to be(true)
      expect(described_class.has_required_tags?(actor, nil)).to be(true)
    end

    it "true when every required tag is supplied by some owned item" do
      equip(actor, "tags" => [ "weapon", "edged" ])
      equip(actor, "tags" => [ "armor", "light" ])
      expect(described_class.has_required_tags?(actor, %w[weapon])).to be(true)
      expect(described_class.has_required_tags?(actor, %w[weapon edged])).to be(true)
      expect(described_class.has_required_tags?(actor, %w[weapon armor])).to be(true)
    end

    it "false when any required tag is missing" do
      equip(actor, "tags" => [ "weapon", "blunt" ])
      expect(described_class.has_required_tags?(actor, %w[weapon edged])).to be(false)
      expect(described_class.has_required_tags?(actor, %w[magical_implement])).to be(false)
    end
  end
end
