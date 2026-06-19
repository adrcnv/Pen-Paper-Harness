require "rails_helper"

RSpec.describe Harness::Runners::Combat do
  let(:yard)    { Location.create!(name: "Mire") }
  let!(:player) { Player.create!(name: "Hero", location: yard, dexterity: 12) }
  let!(:bandit) { Npc.create!(name: "Vek", subrole: "bandit", location: yard, dexterity: 10) }
  let(:step)    { Harness::Dispatcher::Step.new(runner: "combat", intent: "attack Vek", args: {}) }

  def active_scene(at:, present:)
    snap = Struct.new(:location, :present_characters, :present_corpses, :present_items).new(at, present, [], [])
    Harness::Scene::Active.new(location: at, snapshot: snap, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
  end

  def context_with(present:, &block)
    ctx = Harness::Turn::Context.new(player_location: yard, llm_nuance: StubLLM.new(&block), game_time: 100)
    ctx.active_scene = active_scene(at: yard, present: present)
    ctx
  end

  it "enters combat: calls start_combat and returns the :combat terminator" do
    ctx = context_with(present: [ bandit ]) do
      { "player_side" => [ player.id ], "enemy_side" => [ bandit.id ], "inciting_beat" => "the player drew steel on Vek" }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "attack Vek", step: step)

    expect(outcome.status).to eq(:combat)
    expect(outcome.tool_calls.map { |t| t["name"] }).to include("start_combat")
    expect(ctx.active_scene.in_combat?).to be(true)
  end

  it "re-dispatches when no opponent is named" do
    ctx = context_with(present: [ bandit ]) do
      { "player_side" => [ player.id ], "enemy_side" => [], "inciting_beat" => "?" }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "I look menacing", step: step)
    expect(outcome.status).to eq(:redispatch)
    expect(ctx.active_scene.in_combat?).to be(false)
  end
end
