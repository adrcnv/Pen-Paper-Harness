require "rails_helper"

RSpec.describe Harness::Runners::Inventory do
  let(:tavern)  { Location.create!(name: "Tavern") }
  let!(:player) { Player.create!(name: "Hero", location: tavern, coins: 20) }
  let!(:barkeep) { Npc.create!(name: "Tomas", subrole: "barkeep", location: tavern, coins: 5) }
  let!(:locket)  { Item.create!(name: "smooth locket", location: tavern) }
  let(:step)    { Harness::Dispatcher::Step.new(runner: "inventory", intent: "take it", args: {}) }

  def context_with(&block)
    Harness::Turn::Context.new(player_location: tavern, llm_nuance: StubLLM.new(&block), game_time: 100)
  end

  it "picks up an item off the floor" do
    ctx = context_with { { "action" => "pickup", "item_id" => locket.id, "reason" => "pocket it" }.to_json }
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "take the locket", step: step)
    expect(outcome.status).to eq(:ok)
    expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "pickup" ])
    expect(locket.reload.character_id).to eq(player.id)
  end

  it "transfers coins (player defaults as payer)" do
    ctx = context_with { { "action" => "transfer_coins", "to_id" => barkeep.id, "amount" => 3, "reason" => "a tip" }.to_json }
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "tip the barkeep 3 coins", step: step)
    expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "transfer_coins" ])
    expect(player.reload.coins).to eq(17)
    expect(barkeep.reload.coins).to eq(8)
  end

  it "re-dispatches when a transfer lacks recipient/amount" do
    ctx = context_with { { "action" => "transfer_coins", "reason" => "huh" }.to_json }
    scene = Harness::Tools::QueryScene.build(ctx)
    outcome = described_class.new.run(context: ctx, scene: scene, input: "pay", step: step)
    expect(outcome.status).to eq(:redispatch)
  end
end
