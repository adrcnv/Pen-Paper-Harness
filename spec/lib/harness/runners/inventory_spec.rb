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

  describe "shop buy/sell dispatch (to_id is the merchant)" do
    let(:shop) { Location.create!(name: "the Smithy", parent: Location.create!(name: "Town", x: 1, y: 1, properties: { "economic_basis" => "farming", "size" => "town", "wealth" => "modest" }), properties: { "shop" => %w[weapons armor] }) }
    let!(:smith) { Npc.create!(name: "Brann", subrole: "smith", location: shop, coins: 500) }
    let!(:ware) { Item.create!(name: "blade", subrole: "longblade", location: shop, properties: { "tags" => %w[weapon edged], "modifiers" => [], "effects" => [], "for_sale" => true }) }

    before { player.update!(location: shop, coins: 200) }

    it "routes buy → buy_item with to_id as merchant" do
      ctx = context_with { { "action" => "buy", "item_id" => ware.id, "to_id" => smith.id }.to_json }
      scene = Harness::Tools::QueryScene.build(ctx)
      outcome = described_class.new.run(context: ctx, scene: scene, input: "buy the blade", step: step)
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "buy_item" ])
      expect(ware.reload.character_id).to eq(player.id)
    end

    it "routes sell → sell_item with to_id as merchant" do
      owned = Item.create!(name: "my axe", subrole: "longblade", character: player, properties: { "tags" => %w[weapon], "modifiers" => [], "effects" => [] })
      ctx = context_with { { "action" => "sell", "item_id" => owned.id, "to_id" => smith.id }.to_json }
      scene = Harness::Tools::QueryScene.build(ctx)
      outcome = described_class.new.run(context: ctx, scene: scene, input: "sell my axe", step: step)
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "sell_item" ])
      expect(owned.reload.location_id).to eq(shop.id)
    end

    it "re-dispatches buy without a merchant" do
      ctx = context_with { { "action" => "buy", "item_id" => ware.id }.to_json }
      scene = Harness::Tools::QueryScene.build(ctx)
      outcome = described_class.new.run(context: ctx, scene: scene, input: "buy it", step: step)
      expect(outcome.status).to eq(:redispatch)
    end
  end

  describe "open container dispatch" do
    let!(:chest) { Harness::Treasure::Chest.place(location: tavern, rarity: "common", rng: Random.new(1)) }

    it "routes open → open_container" do
      allow(Harness::Dice).to receive(:check).and_return(Harness::Dice::Outcome.new(result: "success", roll: 20, against: 10))
      ctx = context_with { { "action" => "open", "item_id" => chest.id }.to_json }
      scene = Harness::Tools::QueryScene.build(ctx)
      outcome = described_class.new.run(context: ctx, scene: scene, input: "open the chest", step: step)
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "open_container" ])
      expect(chest.reload.properties["state"]).to eq("open")
    end

    it "re-dispatches open without an item_id" do
      ctx = context_with { { "action" => "open" }.to_json }
      scene = Harness::Tools::QueryScene.build(ctx)
      outcome = described_class.new.run(context: ctx, scene: scene, input: "open it", step: step)
      expect(outcome.status).to eq(:redispatch)
    end
  end
end
