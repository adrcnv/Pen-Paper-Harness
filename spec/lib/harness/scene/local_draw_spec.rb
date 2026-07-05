require "rails_helper"

RSpec.describe Harness::Scene::LocalDraw do
  # Mirehold = the city the player is in. Tavern + Smithy are its sublocations;
  # the player is at the Tavern. Osmere = another city. Lair = a wilderness site.
  let(:mirehold) { Location.create!(name: "Mirehold", x: 0.0, y: 0.0) }
  let(:osmere)   { Location.create!(name: "Osmere",   x: 9.0, y: 9.0) }
  let(:tavern)   { Location.create!(name: "Tavern", parent_id: mirehold.id, properties: { "kind" => "sublocation" }) }
  let(:smithy)   { Location.create!(name: "Smithy", parent_id: mirehold.id, properties: { "kind" => "sublocation" }) }
  let(:lair)     { Location.create!(name: "Bend", properties: { "kind" => "wilderness_leaf", "encounter_type" => "combat" }) }

  # rand() (no arg) → the chance roll; rand(n) → a sample index (0 = first).
  fires = Object.new.tap { |o| def o.rand(n = nil) = n ? 0 : 0.0 }
  never = Object.new.tap { |o| def o.rand(n = nil) = n ? 0 : 0.99 }

  def npc(attrs = {})
    @n ||= 0; @n += 1
    Npc.create!({ name: "NPC#{@n}", subrole: "merchant", current_hp: 5, max_hp: 5 }.merge(attrs))
  end

  describe "candidate selection" do
    it "includes a same-city resident living at the city tier, resting at home" do
      local = npc(location_id: mirehold.id, home_location_id: mirehold.id)
      expect(described_class.new(tavern).candidates).to include(local)
    end

    it "includes a resident of a SIBLING sublocation, resting at home" do
      neighbor = npc(location_id: smithy.id, home_location_id: smithy.id)
      expect(described_class.new(tavern).candidates).to include(neighbor)
    end

    it "excludes this sublocation's own residents (already here)" do
      regular = npc(location_id: tavern.id, home_location_id: tavern.id)
      expect(described_class.new(tavern).candidates).not_to include(regular)
    end

    it "excludes residents of OTHER cities (that's TravelerPull's job)" do
      outsider = npc(location_id: osmere.id, home_location_id: osmere.id)
      expect(described_class.new(tavern).candidates).not_to include(outsider)
    end

    it "excludes a resident who isn't currently at home (already out / displaced)" do
      away = npc(location_id: tavern.id, home_location_id: mirehold.id) # home is the city, but standing in the tavern already
      expect(described_class.new(tavern).candidates).not_to include(away)
    end

    it "excludes homeless, dormant, followers, and the dead" do
      homeless = npc(location_id: mirehold.id, home_location_id: nil)
      dormant  = npc(location_id: mirehold.id, home_location_id: mirehold.id, properties: { "dormant" => true })
      follower = npc(location_id: mirehold.id, home_location_id: mirehold.id, properties: { "following_player" => true })
      corpse   = npc(location_id: mirehold.id, home_location_id: mirehold.id, current_hp: 0)

      cands = described_class.new(tavern).candidates
      expect(cands).not_to include(homeless, dormant, follower, corpse)
    end

    it "excludes exclude_ids (anti-cart: the previous scene's cast can't be re-drawn)" do
      just_left = npc(location_id: mirehold.id, home_location_id: mirehold.id)
      other     = npc(location_id: smithy.id,   home_location_id: smithy.id)

      cands = described_class.new(tavern, exclude_ids: [ just_left.id ]).candidates
      expect(cands).not_to include(just_left)
      expect(cands).to include(other)
    end
  end

  describe "maybe_draw" do
    it "relocates a same-city resident into the sublocation when the roll fires" do
      local  = npc(location_id: mirehold.id, home_location_id: mirehold.id)
      pulled = described_class.new(tavern, rng: fires).maybe_draw
      expect(pulled).to eq(local)
      expect(local.reload.location_id).to eq(tavern.id) # now visiting
      expect(local.home_location_id).to eq(mirehold.id) # home untouched → evicted back later
    end

    it "does nothing when the roll doesn't fire" do
      local = npc(location_id: mirehold.id, home_location_id: mirehold.id)
      expect(described_class.new(tavern, rng: never).maybe_draw).to be_nil
      expect(local.reload.location_id).to eq(mirehold.id)
    end

    it "never fires at the city tier (parent_id nil) — residents are already present" do
      npc(location_id: mirehold.id, home_location_id: mirehold.id)
      expect(described_class.new(mirehold, rng: fires).maybe_draw).to be_nil
    end

    it "never fires at a wilderness-leaf sublocation" do
      wild_sub = Location.create!(name: "Hollow", parent_id: lair.id, properties: { "kind" => "wilderness_leaf" })
      npc(location_id: mirehold.id, home_location_id: mirehold.id)
      expect(described_class.new(wild_sub, rng: fires).maybe_draw).to be_nil
    end

    it "is a no-op when there are no eligible locals" do
      expect(described_class.new(tavern, rng: fires).maybe_draw).to be_nil
    end
  end

  describe "day-phase gating" do
    it "never draws at NIGHT even when the roll would fire" do
      npc(location_id: mirehold.id, home_location_id: mirehold.id)
      midnight = 0
      expect(described_class.new(tavern, game_time: midnight, rng: fires).maybe_draw).to be_nil
    end

    it "draws in the EVENING (regulars' hour)" do
      local   = npc(location_id: mirehold.id, home_location_id: mirehold.id)
      evening = 19 * 60
      expect(described_class.new(tavern, game_time: evening, rng: fires).maybe_draw).to eq(local)
    end

    it "falls back to the flat CHANCE when no game_time is supplied" do
      local = npc(location_id: mirehold.id, home_location_id: mirehold.id)
      expect(described_class.new(tavern, rng: fires).maybe_draw).to eq(local)
    end

    it "never draws an ON-SHIFT NPC (the smith stays at his forge at noon); off-shift are fair game" do
      on_shift  = npc(location_id: mirehold.id, home_location_id: mirehold.id, subrole: "smith")
      off_shift = npc(location_id: mirehold.id, home_location_id: mirehold.id, subrole: "minstrel")
      noon      = 12 * 60

      cands = described_class.new(tavern, game_time: noon).candidates
      expect(cands).not_to include(on_shift)
      expect(cands).to include(off_shift)
    end
  end
end
