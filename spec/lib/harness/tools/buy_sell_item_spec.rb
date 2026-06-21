require "rails_helper"

RSpec.describe "buy/sell item tools" do
  let(:context) { Harness::Turn::Context.new(player_location: nil, game_time: 100) }

  let(:city) {
    Location.create!(name: "Brackton", x: 1.0, y: 1.0, biome: "lowland",
                     properties: { "kind" => "city", "economic_basis" => "farming", "size" => "town", "wealth" => "modest" })
  }
  let(:smithy) {
    Location.create!(name: "the Smithy", parent: city,
                     properties: { "kind" => "sublocation", "trade" => "smith", "shop" => %w[weapons armor] })
  }
  let(:player)   { Player.create!(name: "Hero", location: smithy, coins: 500) }
  let(:merchant) { Npc.create!(name: "Smith", subrole: "smith", location: smithy, coins: 100) }

  def ware(tags: %w[weapon edged], modifiers: [ { "stat" => "strength", "value" => 1 } ])
    Item.create!(name: "blade", subrole: "longblade", location: smithy,
                 properties: { "tags" => tags, "modifiers" => modifiers, "effects" => [], "for_sale" => true })
  end

  describe Harness::Tools::BuyItem do
    it "transfers the item to the buyer and the price to the merchant" do
      item = ware
      price = Harness::Economy::Pricing.buy_price(item, wealth: "modest", economic_basis: "farming")
      out = described_class.new.call({ "item_id" => item.id, "merchant_id" => merchant.id, "buyer_id" => player.id }, context)

      expect(out["price"]).to eq(price)
      expect(item.reload.character_id).to eq(player.id)
      expect(item.location_id).to be_nil
      expect(item.properties).not_to have_key("for_sale")
      expect(player.reload.coins).to eq(500 - price)
      expect(merchant.reload.coins).to eq(100 + price)
    end

    it "defaults the buyer to the player" do
      player
      item = ware
      out = described_class.new.call({ "item_id" => item.id, "merchant_id" => merchant.id }, context)
      expect(item.reload.character_id).to eq(player.id)
      expect(out["buyer_id"]).to eq(player.id)
    end

    it "rejects an item that isn't for sale" do
      item = Item.create!(name: "x", subrole: "t", location: smithy, properties: { "tags" => %w[weapon] })
      out = described_class.new.call({ "item_id" => item.id, "merchant_id" => merchant.id, "buyer_id" => player.id }, context)
      expect(out["error"]).to match(/not for sale/)
    end

    it "rejects when the buyer can't afford it" do
      player.update!(coins: 1)
      item = ware(modifiers: [ { "stat" => "strength", "value" => 3 } ])
      out = described_class.new.call({ "item_id" => item.id, "merchant_id" => merchant.id, "buyer_id" => player.id }, context)
      expect(out["error"]).to match(/coins/)
      expect(item.reload.character_id).to be_nil
    end

    it "rejects when the buyer isn't at the shop" do
      elsewhere = Location.create!(name: "Road")
      player.update!(location: elsewhere)
      item = ware
      out = described_class.new.call({ "item_id" => item.id, "merchant_id" => merchant.id, "buyer_id" => player.id }, context)
      expect(out["error"]).to match(/not at the shop/)
    end
  end

  describe Harness::Tools::SellItem do
    it "pays the seller and turns the item into shop stock" do
      owned = Item.create!(name: "loot blade", subrole: "longblade", character: player,
                           properties: { "tags" => %w[weapon edged], "modifiers" => [], "effects" => [] })
      merchant.update!(coins: 1000)
      price = Harness::Economy::Pricing.sell_price(owned, wealth: "modest", economic_basis: "farming")
      out = described_class.new.call({ "item_id" => owned.id, "merchant_id" => merchant.id, "seller_id" => player.id }, context)

      expect(out["price"]).to eq(price)
      expect(owned.reload.character_id).to be_nil
      expect(owned.location_id).to eq(smithy.id)
      expect(owned.properties["for_sale"]).to be(true)
      expect(player.reload.coins).to eq(500 + price)
      expect(merchant.reload.coins).to eq(1000 - price)
    end

    it "refuses a category the shop doesn't deal in" do
      ring = Item.create!(name: "ring", subrole: "ring", character: player,
                          properties: { "tags" => %w[jewelry ring], "modifiers" => [], "effects" => [] })
      out = described_class.new.call({ "item_id" => ring.id, "merchant_id" => merchant.id, "seller_id" => player.id }, context)
      expect(out["error"]).to match(/doesn't deal in/)
    end

    it "rejects when the merchant can't afford the item" do
      owned = Item.create!(name: "fine blade", subrole: "longblade", character: player,
                           properties: { "tags" => %w[weapon], "modifiers" => [ { "stat" => "strength", "value" => 3 } ], "effects" => [] })
      merchant.update!(coins: 0)
      out = described_class.new.call({ "item_id" => owned.id, "merchant_id" => merchant.id, "seller_id" => player.id }, context)
      expect(out["error"]).to match(/can't pay/)
      expect(owned.reload.character_id).to eq(player.id)
    end

    it "rejects selling an item the seller doesn't own" do
      not_mine = Item.create!(name: "x", subrole: "t", location: smithy, properties: { "tags" => %w[weapon] })
      out = described_class.new.call({ "item_id" => not_mine.id, "merchant_id" => merchant.id, "seller_id" => player.id }, context)
      expect(out["error"]).to match(/does not own/)
    end
  end
end
