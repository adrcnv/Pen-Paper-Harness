require "rails_helper"

RSpec.describe Harness::Runners::Meta do
  let(:tavern) { Location.create!(name: "Tavern") }
  let!(:player) { Player.create!(name: "Hero", location: tavern) }
  let(:context) { Harness::Turn::Context.new(player_location: tavern, game_time: 100) }
  let(:step) { Harness::Dispatcher::Step.new(runner: "meta", intent: "OOC comment", args: {}) }

  it "no-ops with an OOC marker, zero LLM, zero state change" do
    expect {
      @outcome = described_class.new.run(context: context, scene: nil, input: "nice plot twist lol", step: step)
    }.not_to change(Event, :count)

    expect(@outcome.status).to eq(:ok)
    expect(@outcome.scene_dirty).to be(false)
    tc = @outcome.tool_calls.first
    expect(tc["name"]).to eq("meta")
    expect(tc.dig("result", "out_of_character")).to be(true)
  end
end
