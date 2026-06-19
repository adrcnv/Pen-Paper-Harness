require "rails_helper"

RSpec.describe Harness::Runners::TimeSkip do
  let(:inn)     { Location.create!(name: "Inn Room") }
  let!(:player) { Player.create!(name: "Hero", location: inn) }
  let(:step)    { Harness::Dispatcher::Step.new(runner: "time-skip", intent: "sleep", args: {}) }

  def context_with(&block)
    Harness::Turn::Context.new(player_location: inn, llm_nuance: StubLLM.new(&block), game_time: 100)
  end

  it "advances the clock via pass_time" do
    ctx = context_with { { "intent" => "sleep", "duration_minutes" => 480 }.to_json }
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "sleep until morning", step: step)
    expect(outcome.status).to eq(:ok)
    expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "pass_time" ])
    expect(ctx.game_time).to be >= 580 # 100 + 480
  end

  it "coerces an invalid intent to 'wait' and a non-positive duration to 60" do
    ctx = context_with { { "intent" => "teleport", "duration_minutes" => 0 }.to_json }
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "wait a bit", step: step)
    expect(outcome.status).to eq(:ok)
    args = outcome.tool_calls.first["args"]
    expect(args["intent"]).to eq("wait")
    expect(args["duration_minutes"]).to eq(60)
  end

  it "re-dispatches (no crash) on unparseable emit" do
    ctx = context_with { "zzz" }
    scene = Harness::Tools::QueryScene.build(ctx)
    outcome = described_class.new.run(context: ctx, scene: scene, input: "rest", step: step)
    expect(outcome.status).to eq(:redispatch)
  end
end
