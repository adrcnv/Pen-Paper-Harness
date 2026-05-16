require "rails_helper"

RSpec.describe Harness::Combat::PlayerFledResolution do
  let(:loc)    { Location.create!(name: "Tavern") }
  let!(:player) { Player.create!(name: "Mud", location: loc, current_hp: 18, max_hp: 20) }
  let!(:vek)    { Npc.create!(name: "Vek",  subrole: "marauder", location: loc, current_hp: 12, max_hp: 18) }
  let!(:rask)   { Npc.create!(name: "Rask", subrole: "marauder", location: loc, current_hp: 6,  max_hp: 14) }

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

  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 0) }

  it "applies killed result by zeroing HP" do
    scene = make_scene
    llm = StubLLM.new {
      ::JSON.generate({
        "summary_prose" => "Vek and Rask brawl until Vek slips and Rask crushes him.",
        "outcomes" => [
          { "character_id" => vek.id,  "result" => "killed", "killer_id" => rask.id },
          { "character_id" => rask.id, "result" => "survived" }
        ]
      })
    }
    out = described_class.run(scene: scene, fight_summary: "round 1: stuff", llm: llm, context: context)
    expect(out["outcomes"]).to be_an(Array)
    expect(vek.reload.current_hp).to eq(0)
    expect(rask.reload.current_hp).to eq(6)
  end

  it "applies fled result by setting location_id to scene parent" do
    scene = make_scene
    parent = Location.create!(name: "City")
    loc.update!(parent: parent)
    llm = StubLLM.new {
      ::JSON.generate({
        "summary_prose" => "Both bandits scatter without their leader.",
        "outcomes" => [
          { "character_id" => vek.id,  "result" => "fled" },
          { "character_id" => rask.id, "result" => "fled" }
        ]
      })
    }
    described_class.run(scene: scene, fight_summary: "x", llm: llm, context: context)
    expect(vek.reload.location_id).to eq(parent.id)
    expect(rask.reload.location_id).to eq(parent.id)
  end

  it "commits a personal-scope event with the wrap-up prose" do
    scene = make_scene
    llm = StubLLM.new {
      ::JSON.generate({
        "summary_prose" => "The marauders take their wins and disappear into the night.",
        "outcomes" => [
          { "character_id" => vek.id,  "result" => "survived" },
          { "character_id" => rask.id, "result" => "survived" }
        ]
      })
    }
    expect { described_class.run(scene: scene, fight_summary: "x", llm: llm, context: context) }.to change { Event.count }.by(1)
    ev = Event.last
    expect(ev.details["details"]).to include("marauders take their wins")
    expect(ev.participants.map(&:id)).to match_array([ vek.id, rask.id ])
  end

  it "falls back to all-survived on malformed JSON" do
    scene = make_scene
    llm = StubLLM.new { "not even close to JSON" }
    out = described_class.run(scene: scene, fight_summary: "x", llm: llm, context: context)
    expect(out["outcomes"].map { |o| o["result"] }).to all(eq("survived"))
  end

  it "skips when there are no remaining combatants" do
    scene = make_scene
    scene.combat.remove_combatant!(vek.id)
    scene.combat.remove_combatant!(rask.id)
    out = described_class.run(scene: scene, fight_summary: "x", llm: nil, context: context)
    expect(out["skipped"]).to be(true)
  end
end
