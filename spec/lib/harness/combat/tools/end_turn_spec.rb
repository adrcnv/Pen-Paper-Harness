require "rails_helper"

RSpec.describe Harness::Combat::Tools::EndTurn do
  let(:loc)    { Location.create!(name: "Tavern") }
  let!(:player) { Player.create!(name: "Mud", location: loc, dexterity: 12) }
  let!(:vek)    { Npc.create!(name: "Vek",  subrole: "marauder", location: loc, dexterity: 14) }

  def make_combat_context
    Harness::Scene::Assembler
    snap   = Harness::Scene::Snapshot.new(location: loc, present_characters: [ player, vek ], present_corpses: [], present_items: [])
    active = Harness::Scene::Active.new(location: loc, snapshot: snap, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
    active.start_combat!
    active.combat.add_combatant(player.id, side: "player_party")
    active.combat.add_combatant(vek.id,    side: "marauders")
    active.combat.initiative = [ player.id, vek.id ]
    ctx = Harness::Turn::Context.new(player_location: loc, game_time: 0)
    ctx.active_scene = active
    ctx
  end

  it "errors when not in combat" do
    Harness::Scene::Assembler
    active = Harness::Scene::Active.new(location: loc, snapshot: nil, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
    ctx = Harness::Turn::Context.new(player_location: loc); ctx.active_scene = active
    out = described_class.new.call({ "actor_id" => player.id }, ctx)
    expect(out["error"]).to eq("not in combat")
  end

  it "errors when actor isn't a combatant" do
    ctx = make_combat_context
    out = described_class.new.call({ "actor_id" => 99_999 }, ctx)
    expect(out["error"]).to match(/not a combatant/)
  end

  it "errors when it isn't the actor's turn" do
    ctx = make_combat_context
    out = described_class.new.call({ "actor_id" => vek.id }, ctx)
    expect(out["error"]).to match(/not actor_id=#{vek.id}'s turn/)
  end

  it "marks both action and move spent and reports slot_complete=true" do
    ctx = make_combat_context
    out = described_class.new.call({ "actor_id" => player.id }, ctx)
    expect(out["error"]).to be_nil
    expect(out["slot_complete"]).to be(true)
    state = ctx.active_scene.combat
    expect(state.acted?(player.id)).to be(true)
    expect(state.moved?(player.id)).to be(true)
  end

  it "is idempotent if either token was already spent" do
    ctx = make_combat_context
    ctx.active_scene.combat.mark_acted!(player.id)
    out = described_class.new.call({ "actor_id" => player.id }, ctx)
    expect(out["error"]).to be_nil
    expect(out["slot_complete"]).to be(true)
  end
end
