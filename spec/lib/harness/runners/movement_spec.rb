require "rails_helper"

RSpec.describe Harness::Runners::Movement do
  let(:city)   { Location.create!(name: "Oakenford") }
  let(:tavern) { Location.create!(name: "The Drowned Rat", parent_id: city.id) }
  let(:smithy) { Location.create!(name: "Smithy", parent_id: city.id) }
  let!(:player) { Player.create!(name: "Hero", location: tavern) }

  # context.llm_nuance is a StubLLM whose block returns canned JSON.
  def context_with(&block)
    Harness::Turn::Context.new(player_location: tavern, llm_nuance: StubLLM.new(&block), game_time: 100)
  end

  def step(intent = "go") = Harness::Dispatcher::Step.new(runner: "movement", intent: intent, args: {})

  it "transitions to an adjacent sibling when the model picks it" do
    smithy # create sibling
    ctx = context_with { { "action" => "transition", "target_id" => smithy.id, "place_name" => nil }.to_json }
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "go to the smithy", step: step)

    expect(outcome.status).to eq(:ok)
    expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "transition" ])
    expect(player.reload.location_id).to eq(smithy.id)
  end

  it "HALTS the turn (no transition) when the player declines the scene-change gate" do
    smithy
    ctx = context_with { { "action" => "transition", "target_id" => smithy.id, "place_name" => nil }.to_json }
    asked = nil
    ctx.confirm_scene_change = ->(name) { asked = name; false }   # player says no
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "is the smithy around?", step: step)

    expect(outcome.status).to eq(:halted)
    expect(outcome.tool_calls).to be_empty              # transition never fired
    expect(player.reload.location_id).to eq(tavern.id)  # stayed put
    expect(asked).to eq("Smithy")                       # confirmer saw the destination name
  end

  it "proceeds normally when the player confirms the gate" do
    smithy
    ctx = context_with { { "action" => "transition", "target_id" => smithy.id, "place_name" => nil }.to_json }
    ctx.confirm_scene_change = ->(_name) { true }
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "go to the smithy", step: step)

    expect(outcome.status).to eq(:ok)
    expect(player.reload.location_id).to eq(smithy.id)
  end

  it "gates travel too — a declined far-destination move halts without querying" do
    ctx = context_with { { "action" => "travel", "place_name" => "Farhold", "target_id" => nil }.to_json }
    ctx.confirm_scene_change = ->(_name) { false }
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "is Farhold far?", step: step)

    expect(outcome.status).to eq(:halted)
    expect(outcome.tool_calls).to be_empty              # not even query_location_by_name ran
  end

  it "re-dispatches when the destination doesn't exist yet (travel lookup miss)" do
    ctx = context_with { { "action" => "travel", "place_name" => "Nowheresville", "target_id" => nil }.to_json }
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "travel to Nowheresville", step: step)

    expect(outcome.status).to eq(:redispatch)
    expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "query_location_by_name" ])
    expect(player.reload.location_id).to eq(tavern.id) # didn't move
  end

  it "yields (early-exit no-op) on a 'none' decision — approaching a present person is not a move" do
    ctx = context_with { { "action" => "none", "target_id" => nil, "place_name" => nil }.to_json }
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "walk up to Marnie", step: step)
    expect(outcome.status).to eq(:ok)              # NOT redispatch — the chain continues
    expect(outcome.tool_calls).to be_empty         # no state change
    expect(player.reload.location_id).to eq(tavern.id)
  end

  it "re-dispatches (does not crash) when the model emits garbage" do
    ctx = context_with { "I am not JSON" }
    scene = Harness::Tools::QueryScene.build(ctx)
    outcome = described_class.new.run(context: ctx, scene: scene, input: "go", step: step)
    expect(outcome.status).to eq(:redispatch)      # genuine decision failure still re-plans
  end

  # Regression: "walk out into a forest" created the place ("The Blackwood")
  # but the movement step re-searched the player's word ("forest"), never
  # matched the invented name, redispatched, and made duplicate forests while
  # the player never moved. The executor now hands the chain-created location
  # straight to movement via step.args, which enters it WITHOUT an LLM call.
  describe "create-then-enter handoff (executor-resolved destination)" do
    it "transitions into a chain-created sublocation, no LLM decision needed" do
      smithy
      ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100) # no llm: proves decide() is skipped
      s = Harness::Dispatcher::Step.new(runner: "movement", intent: "enter",
        args: { "_resolved_destination" => { "id" => smithy.id, "type" => "sublocation", "name" => "Smithy" } })
      scene = Harness::Tools::QueryScene.build(ctx)

      outcome = described_class.new.run(context: ctx, scene: scene, input: "go inside", step: s)

      expect(outcome.status).to eq(:ok)
      expect(outcome.scene_dirty).to be(true)
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "transition" ])
      expect(player.reload.location_id).to eq(smithy.id)
    end

    it "routes a chain-created wilderness_leaf to travel (not transition)" do
      forest = Location.create!(name: "The Blackwood", x: 50.0, y: 50.0, biome: "lowland")
      ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100)
      s = Harness::Dispatcher::Step.new(runner: "movement", intent: "enter",
        args: { "_resolved_destination" => { "id" => forest.id, "type" => "wilderness_leaf", "name" => "The Blackwood" } })
      scene = Harness::Tools::QueryScene.build(ctx)

      outcome = described_class.new.run(context: ctx, scene: scene, input: "walk into the forest", step: s)

      # type → tool mapping: wilderness_leaf goes through travel, never transition.
      names = outcome.tool_calls.map { |t| t["name"] }
      expect(names).to include("travel")
      expect(names).not_to include("transition")
    end
  end
end
