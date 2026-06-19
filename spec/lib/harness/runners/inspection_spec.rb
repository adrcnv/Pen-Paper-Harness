require "rails_helper"

RSpec.describe Harness::Runners::Inspection do
  let(:tavern) { Location.create!(name: "Tavern") }
  let!(:player) { Player.create!(name: "Hero", location: tavern) }
  let(:context) { Harness::Turn::Context.new(player_location: tavern, game_time: 100) }
  let(:step) { Harness::Dispatcher::Step.new(runner: "inspection", intent: "look around", args: {}) }

  it "returns one query_scene tool_call built in Ruby, zero LLM, no writes" do
    scene = Harness::Tools::QueryScene.build(context)
    outcome = described_class.new.run(context: context, scene: scene, input: "look around", step: step)

    expect(outcome.status).to eq(:ok)
    expect(outcome.scene_dirty).to be(false)
    expect(outcome.tool_calls.size).to eq(1)
    tc = outcome.tool_calls.first
    expect(tc["name"]).to eq("query_scene")
    expect(tc["result"]).to include("location")
  end

  it "assembles the scene itself when none is handed in" do
    outcome = described_class.new.run(context: context, scene: nil, input: "look", step: step)
    expect(outcome.tool_calls.first["result"]).to include("present_characters")
  end
end
