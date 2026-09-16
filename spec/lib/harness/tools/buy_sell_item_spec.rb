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

  describe Harness::Tools::SellItem, "to a person" do
    it "a person buys what their trade deals in, at the sell price; a kind outside their trade is refused" do
      trader = Npc.create!(name: "Ora", subrole: "trader", location: city, coins: 50)
      player.update!(location: city)
      pelt  = Item.create!(name: "fox pelt", subrole: "hide", character: player, properties: { "tags" => %w[goods hide], "modifiers" => [], "effects" => [] })
      blade = Item.create!(name: "blade", subrole: "longblade", character: player, properties: { "tags" => %w[weapon edged], "modifiers" => [], "effects" => [] })
      out = described_class.new.call({ "item_id" => pelt.id, "merchant_id" => trader.id, "seller_id" => player.id }, context)
      expect(out["error"]).to be_nil
      expect(pelt.reload.location_id).to eq(city.id)   # on the trader's table now, for sale under their name
      expect(pelt.properties).to include("for_sale" => true, "seller_id" => trader.id)
      expect(trader.reload.coins).to eq(50 - out["price"])
      out = described_class.new.call({ "item_id" => blade.id, "merchant_id" => trader.id, "seller_id" => player.id }, context)
      expect(out["error"]).to include("doesn't deal in that")
      labourer = Npc.create!(name: "Wat", subrole: "labourer", location: city, coins: 50)
      out = described_class.new.call({ "item_id" => blade.id, "merchant_id" => labourer.id, "seller_id" => player.id }, context)
      expect(out["error"]).to include("doesn't buy such things")
    end

    it "in a stocked square a trader buys by his own trade as well as the stalls'; a bystander buys by neither" do
      square = Location.create!(name: "the Market Row", parent: city, properties: { "trade" => "trader", "shop" => %w[weapons armor jewelry] })
      player.update!(location: square)
      zenek  = Npc.create!(name: "Zenek", subrole: "trader", location: square, coins: 50)
      fish   = Item.create!(name: "hot salt fish", subrole: "meal", character: player, properties: { "tags" => %w[provision food], "modifiers" => [], "effects" => [] })
      blade  = Item.create!(name: "blade", subrole: "longblade", character: player, properties: { "tags" => %w[weapon edged], "modifiers" => [], "effects" => [] })
      pelt   = Item.create!(name: "fox pelt", subrole: "hide", character: player, properties: { "tags" => %w[goods hide], "modifiers" => [], "effects" => [] })
      out = described_class.new.call({ "item_id" => fish.id, "merchant_id" => zenek.id, "seller_id" => player.id }, context)
      expect(out["error"]).to be_nil
      out = described_class.new.call({ "item_id" => blade.id, "merchant_id" => zenek.id, "seller_id" => player.id }, context)
      expect(out["error"]).to be_nil
      wat = Npc.create!(name: "Wat", subrole: "labourer", location: square, coins: 50)
      out = described_class.new.call({ "item_id" => pelt.id, "merchant_id" => wat.id, "seller_id" => player.id }, context)
      expect(out["error"]).to include("doesn't buy such things")
    end
  end

  describe Harness::Tools::BuyItem do
    it "pays whoever put the ware on the table, whichever present character is named as merchant" do
      seller = Npc.create!(name: "Tanner", subrole: "tanner", location: smithy, coins: 0)
      pelt = Item.create!(name: "fox pelt", subrole: "hide", location: smithy,
                          properties: { "tags" => %w[goods hide], "modifiers" => [], "effects" => [], "for_sale" => true, "seller_id" => seller.id })
      out = described_class.new.call({ "item_id" => pelt.id, "merchant_id" => merchant.id, "buyer_id" => player.id }, context)
      expect(out["price"]).to be >= 1
      expect(seller.reload.coins).to eq(out["price"])
      expect(merchant.reload.coins).to eq(100)
      expect(pelt.reload.character_id).to eq(player.id)
      expect(pelt.properties).not_to have_key("seller_id")
      expect(Event.order(:id).last.details["summary"]).to eq("Hero bought fox pelt from Tanner for #{out['price']} coins")
    end

    it "refuses a bystander as merchant for shop stock — the keeper or someone of the trade sells it" do
      item   = ware
      patron = Npc.create!(name: "Wat", subrole: "labourer", location: smithy, coins: 0)
      out = described_class.new.call({ "item_id" => item.id, "merchant_id" => patron.id, "buyer_id" => player.id }, context)
      expect(out["error"]).to include("does not keep this stall")
      expect(item.reload.location_id).to eq(smithy.id)
      journeyman = Npc.create!(name: "Ord", subrole: "journeyman smith", location: smithy, coins: 0)   # the venue's trade
      out = described_class.new.call({ "item_id" => item.id, "merchant_id" => journeyman.id, "buyer_id" => player.id }, context)
      expect(out["error"]).to be_nil
      expect(journeyman.reload.coins).to eq(out["price"])
    end

    it "charges a haggled price when one was settled, and clears it with the sale" do
      item = ware
      item.update!(properties: item.properties.merge("haggled_price" => 2))
      out = described_class.new.call({ "item_id" => item.id, "merchant_id" => merchant.id, "buyer_id" => player.id }, context)
      expect(out["price"]).to eq(2)
      expect(player.reload.coins).to eq(498)
      expect(item.reload.properties).not_to have_key("haggled_price")
    end

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
