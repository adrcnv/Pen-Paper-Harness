require "rails_helper"

RSpec.describe Harness::Scene::TravelerPull do
  # Mirehold = the scene the player is in. Osmere = another city, home of a
  # traveler. Lair = a wilderness combat site.
  let(:mirehold) { Location.create!(name: "Mirehold", x: 0.0, y: 0.0) }
  let(:osmere)   { Location.create!(name: "Osmere",   x: 9.0, y: 9.0) }
  let(:tavern)   { Location.create!(name: "Tavern", parent_id: mirehold.id, properties: { "kind" => "sublocation" }) }
  let(:lair)     { Location.create!(name: "Bend", properties: { "kind" => "wilderness_leaf", "encounter_type" => "combat" }) }

  # rand() (no arg) → the chance roll; rand(n) → a sample index (0 = first).
  fires      = Object.new.tap { |o| def o.rand(n = nil) = n ? 0 : 0.0 }
  never      = Object.new.tap { |o| def o.rand(n = nil) = n ? 0 : 0.99 }

  def npc(attrs = {})
    @n ||= 0; @n += 1
    Npc.create!({ name: "NPC#{@n}", subrole: "merchant", current_hp: 5, max_hp: 5 }.merge(attrs))
  end

  describe "candidate selection" do
    it "includes a settlement resident of another city, resting at home" do
      visitor = npc(location_id: osmere.id, home_location_id: osmere.id)
      expect(described_class.new(mirehold).candidates).to include(visitor)
    end

    it "excludes residents of THIS city (and its sublocations)" do
      local      = npc(location_id: mirehold.id, home_location_id: mirehold.id)
      local_sub  = npc(location_id: tavern.id,   home_location_id: tavern.id)
      cands = described_class.new(mirehold).candidates
      expect(cands).not_to include(local, local_sub)
    end

    it "excludes a resident who isn't currently at home (already out / displaced)" do
      away = npc(location_id: mirehold.id, home_location_id: osmere.id) # home Osmere, but here already
      expect(described_class.new(mirehold).candidates).not_to include(away)
    end

    it "excludes homeless, lair-homed, dormant, followers, and the dead" do
      homeless = npc(location_id: osmere.id, home_location_id: nil)
      bandit   = npc(location_id: lair.id,   home_location_id: lair.id) # home is a lair, not a settlement
      dormant  = npc(location_id: osmere.id, home_location_id: osmere.id, properties: { "dormant" => true })
      follower = npc(location_id: osmere.id, home_location_id: osmere.id, properties: { "following_player" => true })
      corpse   = npc(location_id: osmere.id, home_location_id: osmere.id, current_hp: 0)

      cands = described_class.new(mirehold).candidates
      expect(cands).not_to include(homeless, bandit, dormant, follower, corpse)
    end

    it "excludes exclude_ids (anti-cart: nobody tails the player across cities)" do
      just_left = npc(location_id: osmere.id, home_location_id: osmere.id)
      other     = npc(location_id: osmere.id, home_location_id: osmere.id)

      cands = described_class.new(mirehold, exclude_ids: [ just_left.id ]).candidates
      expect(cands).not_to include(just_left)
      expect(cands).to include(other)
    end
  end

  describe "maybe_pull" do
    it "relocates a far-home resident into the scene when the roll fires" do
      visitor = npc(location_id: osmere.id, home_location_id: osmere.id)
      pulled  = described_class.new(mirehold, rng: fires).maybe_pull
      expect(pulled).to eq(visitor)
      expect(visitor.reload.location_id).to eq(mirehold.id) # now visiting
      expect(visitor.home_location_id).to eq(osmere.id)     # home untouched → evicted back later
    end

    it "does nothing when the roll doesn't fire" do
      visitor = npc(location_id: osmere.id, home_location_id: osmere.id)
      expect(described_class.new(mirehold, rng: never).maybe_pull).to be_nil
      expect(visitor.reload.location_id).to eq(osmere.id)
    end

    it "never pulls a traveler into a non-settlement scene" do
      npc(location_id: osmere.id, home_location_id: osmere.id)
      expect(described_class.new(lair, rng: fires).maybe_pull).to be_nil
    end

    it "is a no-op when there are no eligible travelers" do
      expect(described_class.new(mirehold, rng: fires).maybe_pull).to be_nil
    end
  end

  describe "day-phase gating" do
    it "never pulls at NIGHT even when the roll would fire" do
      npc(location_id: osmere.id, home_location_id: osmere.id)
      midnight = 0
      expect(described_class.new(mirehold, game_time: midnight, rng: fires).maybe_pull).to be_nil
    end

    it "pulls by DAY (the road is busy)" do
      visitor = npc(location_id: osmere.id, home_location_id: osmere.id)
      noon    = 12 * 60
      expect(described_class.new(mirehold, game_time: noon, rng: fires).maybe_pull).to eq(visitor)
    end

    it "falls back to the flat CHANCE when no game_time is supplied" do
      visitor = npc(location_id: osmere.id, home_location_id: osmere.id)
      expect(described_class.new(mirehold, rng: fires).maybe_pull).to eq(visitor)
    end
  end
end
