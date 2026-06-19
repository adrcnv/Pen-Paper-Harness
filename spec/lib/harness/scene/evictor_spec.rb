require "rails_helper"

RSpec.describe Harness::Scene::Evictor do
  # Osmere is a settlement (no `kind`); the Crossing is a wilderness_leaf
  # (encounter site) just beside it; the Tavern is a sublocation of Osmere.
  let(:osmere)   { Location.create!(name: "Osmere",   x: 91.5, y: 51.5, biome: "lowland") }
  let(:crossing) { Location.create!(name: "Crossing", x: 91.1, y: 49.5, biome: "lowland", properties: { "kind" => "wilderness_leaf" }) }
  let(:tavern)   { Location.create!(name: "Tavern", parent_id: osmere.id, properties: { "kind" => "sublocation" }) }

  def npc(attrs = {})
    @n ||= 0
    @n += 1
    Npc.create!({ name: "NPC#{@n}", subrole: "merchant", current_hp: 5, max_hp: 5 }.merge(attrs))
  end

  it "leaves a resident (home == here) in place" do
    n = npc(location_id: osmere.id, home_location_id: osmere.id)
    described_class.evict!(osmere)
    expect(n.reload.location_id).to eq(osmere.id)
  end

  it "sends a displaced dweller home (home != here)" do
    n = npc(location_id: crossing.id, home_location_id: osmere.id)
    described_class.evict!(crossing)
    expect(n.reload.location_id).to eq(osmere.id)
  end

  it "culls a homeless flavor transient with no events" do
    n = npc(location_id: crossing.id, home_location_id: nil)
    described_class.evict!(crossing)
    expect(Npc.exists?(n.id)).to be(false)
  end

  it "grants a homeless but event-bound transient a home (nearest settlement) and sends them there" do
    osmere # the nearest coordinated settlement must exist to rehome to it
    n  = npc(location_id: crossing.id, home_location_id: nil)
    ev = Event.create!(game_time: 100, location_id: crossing.id, details: {}, scope: "local")
    EventParticipant.create!(event: ev, character: n, role: "actor")

    described_class.evict!(crossing)
    n.reload
    expect(n.location_id).to eq(osmere.id)      # nearest coordinated settlement
    expect(n.home_location_id).to eq(osmere.id) # and now lives there
    expect(Npc.exists?(n.id)).to be(true)        # not culled — the player made them real
  end

  it "leaves a lair dweller at his lair (the bandit you fought is here again next time)" do
    lair = Location.create!(name: "Ambush Bend", x: 80.0, y: 20.0, biome: "lowland",
                            properties: { "kind" => "wilderness_leaf", "encounter_type" => "combat" })
    bandit = npc(location_id: lair.id, home_location_id: lair.id) # home == here (lair)
    described_class.evict!(lair)
    expect(bandit.reload.location_id).to eq(lair.id) # stays — re-encounter toll preserved
  end

  it "never evicts a follower (rides with the player instead)" do
    n = npc(location_id: crossing.id, home_location_id: osmere.id, properties: { "following_player" => true })
    described_class.evict!(crossing)
    expect(n.reload.location_id).to eq(crossing.id)
  end

  it "never evicts a corpse" do
    n = npc(location_id: crossing.id, home_location_id: osmere.id, current_hp: 0)
    described_class.evict!(crossing)
    expect(n.reload.location_id).to eq(crossing.id)
  end

  it "never evicts a dormant historical" do
    n = npc(location_id: crossing.id, home_location_id: nil, properties: { "dormant" => true })
    described_class.evict!(crossing)
    expect(Npc.exists?(n.id)).to be(true)
    expect(n.reload.location_id).to eq(crossing.id)
  end
end
