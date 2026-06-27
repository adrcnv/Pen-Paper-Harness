require "rails_helper"

RSpec.describe Harness::Dispatcher do
  let(:tavern) { Location.create!(name: "Tavern") }
  let(:context) { Harness::Turn::Context.new(player_location: tavern, game_time: 100) }
  let(:scene_manager) { instance_double(Harness::Scene::Manager) }
  let(:registry) { { "inspection" => Harness::Runners::Inspection.new } }
  subject(:dispatcher) { described_class.new(context: context, scene_manager: scene_manager, registry: registry) }

  def stub_planner(plan: nil, parse_error: nil, raw: "", ms: 5, model: "fake")
    allow(Harness::Shadow::Planner).to receive(:plan_for).and_return(
      "plan" => plan, "parse_error" => parse_error, "raw" => raw,
      "duration_ms" => ms, "model" => model, "world" => {}
    )
  end

  describe "#plan" do
    it "maps planner output to Step structs (runner + intent + args)" do
      stub_planner(plan: [
        { "runner" => "movement",     "reason" => "go to the docks", "args" => { "dest" => "docks" } },
        { "runner" => "conversation", "reason" => "ask the barkeep", "args" => {} }
      ])
      plan = dispatcher.plan("go to the docks and ask the barkeep")

      expect(plan.failed?).to be(false)
      expect(plan.steps.map(&:runner)).to eq(%w[movement conversation])
      expect(plan.steps.first.intent).to eq("go to the docks")
      expect(plan.steps.first.args).to eq("dest" => "docks")
    end

    # Regression: the standalone "dice" runner was retired (a roll belongs
    # inside an interaction, not its own step). A weak local model may still
    # emit "dice" from habit; it must remap to "environment" so the turn does
    # NOT fall back to agentic on an unbuilt label.
    it "remaps a retired 'dice' step to 'environment'" do
      stub_planner(plan: [ { "runner" => "dice", "reason" => "climb the wall", "args" => {} } ])
      plan = dispatcher.plan("climb the wall")
      expect(plan.steps.map(&:runner)).to eq(%w[environment])
    end

    it "flags a parse failure without raising" do
      stub_planner(plan: nil, parse_error: "missing 'plan' array", raw: "garbage")
      plan = dispatcher.plan("???")
      expect(plan.failed?).to be(true)
      expect(plan.steps).to eq([])
    end

    it "treats an empty plan as empty, not failed" do
      stub_planner(plan: [])
      plan = dispatcher.plan("look around")
      expect(plan.failed?).to be(false)
      expect(plan.empty?).to be(true)
    end
  end

  describe "#built? / #runner_for" do
    it "knows which labels have a real runner" do
      expect(dispatcher.built?("inspection")).to be(true)
      expect(dispatcher.built?("movement")).to be(false)
      expect(dispatcher.runner_for("inspection")).to be_a(Harness::Runners::Inspection)
      expect(dispatcher.runner_for("movement")).to be_nil
    end
  end
end
