require "rails_helper"

RSpec.describe Harness::Combat::Termination do
  let(:loc)    { Location.create!(name: "Tavern") }
  let!(:player) { Player.create!(name: "Mud", location: loc, current_hp: 20, max_hp: 20) }
  let!(:vek)    { Npc.create!(name: "Vek",  subrole: "marauder", location: loc, current_hp: 18, max_hp: 18) }
  let!(:rask)   { Npc.create!(name: "Rask", subrole: "marauder", location: loc, current_hp: 14, max_hp: 14) }

  def make_scene
    Harness::Scene::Assembler
    snap   = Harness::Scene::Snapshot.new(location: loc, present_characters: [ player, vek, rask ], present_corpses: [], present_items: [])
    active = Harness::Scene::Active.new(location: loc, snapshot: snap, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
    active.start_combat!
    active.combat.add_combatant(player.id, side: "player_party")
    active.combat.add_combatant(vek.id,    side: "marauders")
    active.combat.add_combatant(rask.id,   side: "marauders")
    active
  end

  it "returns nil when both sides have alive members" do
    scene = make_scene
    expect(described_class.evaluate(scene)).to be_nil
  end

  it "returns :victory when one side is wiped" do
    scene = make_scene
    vek.update!(current_hp: 0)
    rask.update!(current_hp: 0)
    expect(described_class.evaluate(scene)).to eq(:victory)
  end

  it "returns :player_died when player current_hp <= 0" do
    scene = make_scene
    player.update!(current_hp: 0)
    expect(described_class.evaluate(scene)).to eq(:player_died)
  end

  it "returns :player_fled when player.location_id != scene.location.id" do
    scene = make_scene
    other = Location.create!(name: "Elsewhere")
    player.update!(location_id: other.id)
    expect(described_class.evaluate(scene)).to eq(:player_fled)
  end

  it "returns :all_fled when every side is empty (everyone removed)" do
    scene = make_scene
    scene.combat.remove_combatant!(player.id)
    scene.combat.remove_combatant!(vek.id)
    scene.combat.remove_combatant!(rask.id)
    expect(described_class.evaluate(scene)).to eq(:all_fled)
  end
end
