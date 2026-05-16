require "rails_helper"

RSpec.describe PendingAppearance do
  let(:city)     { Location.create!(name: "Saltmere") }
  let(:tavern)   { Location.create!(name: "Tavern", parent: city) }
  let(:player)   { Player.create!(name: "Hero",  location: tavern) }
  let(:joey)     { Npc.create!(name: "Joey",     subrole: "patron",  location: tavern) }
  let(:guild)   { Faction.create!(name: "Shadow Hand", subrole: "thieves_guild", is_kingdom: false) }

  def base_attrs
    {
      target_character: player,
      intent_text:      "wants payment",
      anchor_location:  tavern,
      scope:            "local",
      earliest_at:      1000
    }
  end

  describe "validations" do
    it "saves a class-4-actor appearance (origin_character + actor_character)" do
      pa = described_class.new(base_attrs.merge(origin_character: joey, actor_character: joey))
      expect(pa).to be_valid
      expect { pa.save! }.not_to raise_error
    end

    it "saves a faceless appearance with origin_faction (no actor specified)" do
      pa = described_class.new(base_attrs.merge(origin_faction: guild))
      expect(pa).to be_valid
    end

    it "rejects a faceless appearance with no origin_faction" do
      pa = described_class.new(base_attrs)
      expect(pa).not_to be_valid
      expect(pa.errors[:base].join).to include("requires origin_faction_id")
    end

    it "rejects when both origin_character and origin_faction are set" do
      pa = described_class.new(base_attrs.merge(origin_character: joey, origin_faction: guild, actor_character: joey))
      expect(pa).not_to be_valid
      expect(pa.errors[:base].join).to include("origin_character_id and origin_faction_id are mutually exclusive")
    end

    it "rejects scope outside the allowed set" do
      pa = described_class.new(base_attrs.merge(origin_faction: guild, scope: "kingdom"))
      expect(pa).not_to be_valid
    end

    it "requires anchor_location unless scope=anywhere" do
      bad  = described_class.new(base_attrs.merge(origin_faction: guild, anchor_location: nil, scope: "local"))
      good = described_class.new(base_attrs.merge(origin_faction: guild, anchor_location: nil, scope: "anywhere"))
      expect(bad).not_to be_valid
      expect(bad.errors[:anchor_location_id]).to include(/required/)
      expect(good).to be_valid
    end
  end

  describe "scopes and resolve!" do
    it "for_target + unresolved + firable_at composes for the resolution query" do
      old = described_class.create!(base_attrs.merge(origin_faction: guild, earliest_at: 500))
      future = described_class.create!(base_attrs.merge(origin_faction: guild, earliest_at: 9000))
      already = described_class.create!(base_attrs.merge(origin_faction: guild, earliest_at: 500, resolved_at: 600))

      hits = described_class.for_target(player).unresolved.firable_at(2000)
      expect(hits).to contain_exactly(old)
    end

    it "resolve! sets resolved_at and is idempotent" do
      pa = described_class.create!(base_attrs.merge(origin_faction: guild))
      pa.resolve!(2500)
      expect(pa.reload.resolved_at).to eq(2500)
      pa.resolve!(9999)
      expect(pa.reload.resolved_at).to eq(2500)  # idempotent
    end
  end

  describe "named_actor?" do
    it "true when actor_character_id set" do
      pa = described_class.new(base_attrs.merge(origin_character: joey, actor_character: joey))
      expect(pa.named_actor?).to be(true)
    end
    it "false when no actor_character" do
      pa = described_class.new(base_attrs.merge(origin_faction: guild))
      expect(pa.named_actor?).to be(false)
    end
  end
end
