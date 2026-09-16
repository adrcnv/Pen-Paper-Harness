require "rails_helper"

RSpec.describe Harness::Tools::TradeItems do
  let(:context) { Harness::Turn::Context.new(player_location: nil, game_time: 100) }
  let(:city)    { Location.create!(name: "Norddal", x: 1.0, y: 1.0, biome: "lowland", properties: { "kind" => "city", "economic_basis" => "herding", "size" => "hamlet", "wealth" => "modest" }) }
  let(:shed)    { Location.create!(name: "the Mending Shed", parent: city) }
  let(:player)  { Player.create!(name: "Annwyn", location: shed, coins: 5) }
  let(:fisher)  { Npc.create!(name: "Sigebert", subrole: "fisher", location: shed, coins: 0) }
  let(:shirt)   { Item.create!(name: "plain chain shirt", subrole: "chain", character: player, properties: { "tags" => %w[armor medium], "modifiers" => [ { "stat" => "constitution", "op" => "add", "value" => 2 } ], "effects" => [] }) }
  def ware(name) = Item.create!(name: name, subrole: "meal", location: shed, properties: { "tags" => %w[provision food], "modifiers" => [], "effects" => [], "for_sale" => true, "seller_id" => fisher.id })

  it "swaps a carried item for the seller's wares when its value covers them — no coin moves, both memories get a line" do
    fish = ware("thin salt fish"); ale = ware("dark ale")
    out = described_class.new.call({ "item_id" => shirt.id, "for_item_ids" => [ fish.id, ale.id ], "with_id" => fisher.id, "trader_id" => player.id }, context)
    expect(out["error"]).to be_nil
    expect(shirt.reload.character_id).to eq(fisher.id)
    expect([ fish.reload.character_id, ale.reload.character_id ]).to all(eq(player.id))
    expect(fish.properties).not_to include("for_sale", "seller_id")
    expect(player.reload.coins).to eq(5)
    expect(Event.order(:id).last.details["summary"]).to eq("Annwyn traded plain chain shirt to Sigebert for thin salt fish and dark ale")
  end

  it "coins on top count toward the swap and change hands with it" do
    fish = ware("thin salt fish")
    pelt = Item.create!(name: "fox pelt", subrole: "hide", character: player, properties: { "tags" => %w[goods hide], "modifiers" => [], "effects" => [] })
    dear = Item.create!(name: "bolt of cloth", subrole: "cloth", location: shed, properties: { "tags" => %w[goods cloth], "modifiers" => [], "effects" => [], "for_sale" => true, "seller_id" => fisher.id, "haggled_price" => 6 })
    out = described_class.new.call({ "item_id" => pelt.id, "for_item_ids" => [ dear.id ], "with_id" => fisher.id, "trader_id" => player.id, "coins" => 1 }, context)
    expect(out["error"]).to include("won't take fox pelt and 1 coins")
    expect(player.reload.coins).to eq(5)

    out = described_class.new.call({ "item_id" => pelt.id, "for_item_ids" => [ dear.id ], "with_id" => fisher.id, "trader_id" => player.id, "coins" => 4 }, context)
    expect(out["error"]).to be_nil
    expect(out["coins"]).to eq(4)
    expect(dear.reload.character_id).to eq(player.id)
    expect(pelt.reload.character_id).to eq(fisher.id)
    expect([ player.reload.coins, fisher.reload.coins ]).to eq([ 1, 4 ])
    expect(Event.order(:id).last.details["summary"]).to eq("Annwyn traded fox pelt and 4 coins to Sigebert for bolt of cloth")

    out = described_class.new.call({ "item_id" => shirt.id, "for_item_ids" => [ fish.id ], "with_id" => fisher.id, "trader_id" => player.id, "coins" => 9 }, context)
    expect(out["error"]).to include("has 1 coins, not 9")
  end

  it "refuses a swap the value does not cover, and wares that are not the counterparty's" do
    pelt = Item.create!(name: "fox pelt", subrole: "hide", character: player, properties: { "tags" => %w[goods hide], "modifiers" => [], "effects" => [] })
    dear = Item.create!(name: "silvered fetish", subrole: "fetish", location: shed, properties: { "tags" => %w[jewelry magical], "modifiers" => [], "effects" => [ { "trigger" => "heal_on_kill", "params" => {} } ], "for_sale" => true, "seller_id" => fisher.id })
    out = described_class.new.call({ "item_id" => pelt.id, "for_item_ids" => [ dear.id ], "with_id" => fisher.id, "trader_id" => player.id }, context)
    expect(out["error"]).to include("won't take")
    expect(pelt.reload.character_id).to eq(player.id)

    other = Npc.create!(name: "Mereth", subrole: "net_mender", location: shed)
    fish  = ware("thin salt fish")
    out = described_class.new.call({ "item_id" => shirt.id, "for_item_ids" => [ fish.id ], "with_id" => other.id, "trader_id" => player.id }, context)
    expect(out["error"]).to include("not Mereth's to trade")
    expect(shirt.reload.character_id).to eq(player.id)
  end
end
