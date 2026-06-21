require "rails_helper"

RSpec.describe Harness::Runners::Environment do
  let(:loc) { Location.create!(name: "Clearing") }
  let!(:player) {
    Player.create!(name: "Hero", location: loc, charisma: 14,
                   abilities: [ { "name" => "Wild Surge", "stat" => "charisma", "uses_remaining" => 3 } ])
  }
  let(:step) { Harness::Dispatcher::Step.new(runner: "environment", intent: "act on an object", args: {}) }

  def ctx_emitting(payload)
    json = payload.is_a?(String) ? payload : payload.to_json
    Harness::Turn::Context.new(player_location: loc, llm_nuance: StubLLM.new { json }, game_time: 100)
  end

  def run(ctx, input)
    described_class.new.run(context: ctx, scene: nil, input: input, step: step)
  end

  def names(out) = out.tool_calls.map { |t| t["name"] }

  it "pure flavor (all null) emits nothing but succeeds" do
    out = run(ctx_emitting("action" => "kick the locked gate", "roll" => nil, "yields_item" => nil, "location_change" => nil), "kick the gate")
    expect(out.status).to eq(:ok)
    expect(out.tool_calls).to be_empty
  end

  it "spawns a collectible item anchored to the current location" do
    out = run(ctx_emitting(
      "action" => "snap dry branches", "roll" => nil,
      "yields_item" => { "name" => "bundle of firewood", "subrole" => "firewood" }, "location_change" => nil
    ), "gather firewood")
    item_tc = out.tool_calls.find { |t| t["name"] == "propose_item" }
    expect(item_tc).to be_present
    expect(item_tc.dig("args", "location_id")).to eq(loc.id)
    expect(Item.where(location_id: loc.id)).to be_present
  end

  it "rolls an uncertain act, then yields the item on SUCCESS" do
    allow(Harness::Dice).to receive(:check).and_return(
      Harness::Dice::Outcome.new(result: "success", margin: "clear", critical: false)
    )
    out = run(ctx_emitting(
      "action" => "blast the tree apart", "time_minutes" => 2,
      "roll" => { "ability_name" => "Wild Surge", "difficulty" => "moderate" },
      "yields_item" => { "name" => "splintered wood", "subrole" => "firewood" }
    ), "blast the tree")
    expect(names(out)).to include("resolve", "propose_item")
  end

  it "WITHHOLDS the item (and any change) when the roll FAILS" do
    allow(Harness::Dice).to receive(:check).and_return(
      Harness::Dice::Outcome.new(result: "failure", margin: "narrow", critical: false)
    )
    out = run(ctx_emitting(
      "action" => "blast the tree apart",
      "roll" => { "ability_name" => "Wild Surge", "difficulty" => "moderate" },
      "yields_item" => { "name" => "splintered wood", "subrole" => "firewood" },
      "location_change" => "the tree is reduced to a stump"
    ), "blast the tree")
    expect(names(out)).to include("resolve")
    expect(names(out)).not_to include("propose_item", "mutate_location")
  end

  it "records a persistent location change via mutate_location" do
    out = run(ctx_emitting(
      "action" => "barricade the door", "roll" => nil, "yields_item" => nil,
      "location_change" => "the door is barricaded shut"
    ), "bar the door")
    expect(names(out)).to include("mutate_location")
    expect(loc.reload.properties["alterations"]).to include("the door is barricaded shut")
  end

  it "redispatches on an unparseable emit" do
    out = run(ctx_emitting("not json at all"), "do something")
    expect(out.status).to eq(:redispatch)
  end
end
