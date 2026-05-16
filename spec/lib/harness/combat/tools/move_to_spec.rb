require "rails_helper"

RSpec.describe Harness::Combat::Tools::MoveTo do
  let(:loc)    { Location.create!(name: "Tavern") }
  let!(:player) { Player.create!(name: "Mud", location: loc, dexterity: 12) }
  let!(:vek)    { Npc.create!(name: "Vek",  subrole: "marauder", location: loc, dexterity: 14) }
  let!(:rask)   { Npc.create!(name: "Rask", subrole: "marauder", location: loc, dexterity: 10) }

  def make_combat_context
    Harness::Scene::Assembler
    snap   = Harness::Scene::Snapshot.new(location: loc, present_characters: [ player, vek, rask ], present_corpses: [], present_items: [])
    active = Harness::Scene::Active.new(location: loc, snapshot: snap, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
    active.start_combat!
    active.combat.add_combatant(player.id, side: "player_party")
    active.combat.add_combatant(vek.id,    side: "marauders")
    active.combat.add_combatant(rask.id,   side: "marauders")
    active.combat.initiative = [ player.id, vek.id, rask.id ]
    ctx = Harness::Turn::Context.new(player_location: loc, game_time: 0)
    ctx.active_scene = active
    ctx
  end

  it "errors when not in combat" do
    Harness::Scene::Assembler
    snap   = Harness::Scene::Snapshot.new(location: loc, present_characters: [ player ], present_corpses: [], present_items: [])
    active = Harness::Scene::Active.new(location: loc, snapshot: snap, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
    ctx = Harness::Turn::Context.new(player_location: loc); ctx.active_scene = active
    out = described_class.new.call({ "actor_id" => player.id, "position" => "near" }, ctx)
    expect(out["error"]).to eq("not in combat")
  end

  it "errors when actor isn't a combatant" do
    ctx = make_combat_context
    stranger = Npc.create!(name: "Stranger", location: Location.create!(name: "Elsewhere"))
    out = described_class.new.call({ "actor_id" => stranger.id, "position" => "near" }, ctx)
    expect(out["error"]).to match(/not a combatant/)
  end

  it "errors when it is not the actor's turn" do
    ctx = make_combat_context
    out = described_class.new.call({ "actor_id" => vek.id, "position" => "far" }, ctx)
    expect(out["error"]).to match(/not actor_id=#{vek.id}'s turn/)
  end

  it "errors when actor has already moved" do
    ctx = make_combat_context
    ctx.active_scene.combat.mark_moved!(player.id)
    out = described_class.new.call({ "actor_id" => player.id, "position" => "far" }, ctx)
    expect(out["error"]).to match(/already moved/)
  end

  it "errors on invalid position" do
    ctx = make_combat_context
    out = described_class.new.call({ "actor_id" => player.id, "position" => "behind" }, ctx)
    expect(out["error"]).to match(/position must be one of/)
  end

  it "moving to engaged requires target_id" do
    ctx = make_combat_context
    out = described_class.new.call({ "actor_id" => player.id, "position" => "engaged" }, ctx)
    expect(out["error"]).to match(/requires target_id/)
  end

  it "moving to engaged rejects unknown target" do
    ctx = make_combat_context
    out = described_class.new.call({ "actor_id" => player.id, "position" => "engaged", "target_id" => 99_999 }, ctx)
    expect(out["error"]).to match(/not a combatant/)
  end

  it "moving to engaged rejects engaging self" do
    ctx = make_combat_context
    out = described_class.new.call({ "actor_id" => player.id, "position" => "engaged", "target_id" => player.id }, ctx)
    expect(out["error"]).to match(/cannot engage yourself/)
  end

  it "moving to engaged sets symmetric engagement edge and both positions" do
    ctx = make_combat_context
    out = described_class.new.call({ "actor_id" => player.id, "position" => "engaged", "target_id" => vek.id }, ctx)
    expect(out["error"]).to be_nil
    state = ctx.active_scene.combat
    expect(state.position_of(player.id)).to eq("engaged")
    expect(state.position_of(vek.id)).to eq("engaged")
    expect(state.engaged_with_of(player.id)).to eq(vek.id)
    expect(state.engaged_with_of(vek.id)).to eq(player.id)
    expect(state.moved?(player.id)).to be(true)
  end

  it "switching engagement target disengages from the previous one" do
    ctx = make_combat_context
    state = ctx.active_scene.combat
    state.engage!(player.id, vek.id)
    out = described_class.new.call({ "actor_id" => player.id, "position" => "engaged", "target_id" => rask.id }, ctx)
    expect(out["error"]).to be_nil
    expect(state.engaged_with_of(player.id)).to eq(rask.id)
    expect(state.engaged_with_of(rask.id)).to eq(player.id)
    expect(state.engaged_with_of(vek.id)).to be_nil
  end

  it "moving away from engaged auto-disengages both sides" do
    ctx = make_combat_context
    state = ctx.active_scene.combat
    state.engage!(player.id, vek.id)
    out = described_class.new.call({ "actor_id" => player.id, "position" => "far" }, ctx)
    expect(out["error"]).to be_nil
    expect(state.position_of(player.id)).to eq("far")
    expect(state.engaged_with_of(player.id)).to be_nil
    expect(state.engaged_with_of(vek.id)).to be_nil
  end

  it "near→far / far→near are simple position swaps" do
    ctx = make_combat_context
    state = ctx.active_scene.combat
    state.set_position!(player.id, "far")
    out = described_class.new.call({ "actor_id" => player.id, "position" => "near" }, ctx)
    expect(out["from_position"]).to eq("far")
    expect(out["to_position"]).to eq("near")
  end

  it "reports slot_complete=false when only move spent" do
    ctx = make_combat_context
    out = described_class.new.call({ "actor_id" => player.id, "position" => "far" }, ctx)
    expect(out["slot_complete"]).to be(false)
  end

  it "reports slot_complete=true when both action and move spent" do
    ctx = make_combat_context
    ctx.active_scene.combat.mark_acted!(player.id)
    out = described_class.new.call({ "actor_id" => player.id, "position" => "far" }, ctx)
    expect(out["slot_complete"]).to be(true)
  end
end
