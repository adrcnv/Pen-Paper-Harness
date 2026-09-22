require "rails_helper"

RSpec.describe Harness::Dispatcher do
  let(:tavern) { Location.create!(name: "Tavern") }
  let(:context) { Harness::Turn::Context.new(player_location: tavern, game_time: 100) }
  let(:scene_manager) { instance_double(Harness::Scene::Manager) }
  let(:registry) { { "inspection" => Harness::Runners::Inspection.new } }
  subject(:dispatcher) { described_class.new(context: context, scene_manager: scene_manager, registry: registry) }

  def stub_planner(plan: nil, parse_error: nil, raw: "", ms: 5, model: "fake")
    allow(Harness::Planner).to receive(:plan_for).and_return(
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
      expect(plan.steps.map(&:runner)).to eq(%w[movement inventory conversation])   # the hands step is implicit, see below
      expect(plan.steps.first.intent).to eq("go to the docks")
      expect(plan.steps.first.args).to eq("dest" => "docks")
    end

    it "puts an implicit hands step before a conversation the planner wrote no inventory step beside — whether the hands move is the inventory judge's question (hands run 9 t18)" do
      stub_planner(plan: [ { "runner" => "movement", "reason" => "go" }, { "runner" => "conversation", "reason" => "say it" } ])
      steps = dispatcher.plan("go and say it").steps
      expect(steps.map(&:runner)).to eq(%w[movement inventory conversation])
      expect(steps[1].args).to eq("implicit" => true)
      expect(steps[1].intent).to be_nil
      stub_planner(plan: [ { "runner" => "conversation", "reason" => "say it" }, { "runner" => "inventory", "reason" => "hand it over" } ])
      expect(dispatcher.plan("say it, hand it over").steps.map { |s| [ s.runner, s.args["implicit"] ] }).to eq([ [ "inventory", nil ], [ "conversation", nil ] ])
      stub_planner(plan: [ { "runner" => "inspection", "reason" => "look" } ])
      expect(dispatcher.plan("look").steps.map(&:runner)).to eq(%w[inspection])
    end

    # Retired labels (dice/agentic) are gone from the grammar enum — the
    # sampler cannot emit them. A stray label (unconstrained-fallback path
    # only) passes through untouched; the EXECUTOR degrades unbuilt labels
    # to inspection (see executor_spec).
    it "runs the player's own hands before the room answers: an inventory step written after a conversation step moves ahead of it; a movement between keeps its place" do
      stub_planner(plan: [ { "runner" => "conversation", "reason" => "say it" }, { "runner" => "inventory", "reason" => "pay" } ])
      expect(dispatcher.plan("'I'll take it.' Hand over 47 coins.").steps.map(&:runner)).to eq(%w[inventory conversation])
      stub_planner(plan: [ { "runner" => "movement", "reason" => "go" }, { "runner" => "conversation", "reason" => "say it" }, { "runner" => "inventory", "reason" => "pay" } ])
      expect(dispatcher.plan("go, say, pay").steps.map(&:runner)).to eq(%w[movement inventory conversation])
      stub_planner(plan: [ { "runner" => "conversation", "reason" => "ask" }, { "runner" => "movement", "reason" => "walk" }, { "runner" => "inventory", "reason" => "buy" } ])
      expect(dispatcher.plan("ask, walk, buy").steps.map(&:runner)).to eq(%w[conversation movement inventory])
    end

    it "passes an unknown label through for the executor to degrade" do
      stub_planner(plan: [ { "runner" => "dice", "reason" => "climb the wall", "args" => {} } ])
      plan = dispatcher.plan("climb the wall")
      expect(plan.steps.map(&:runner)).to eq(%w[dice])
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
