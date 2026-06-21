require "rails_helper"

RSpec.describe Harness::Economy::Pricing do
  let(:sword)  { Item.new(name: "sword", subrole: "longblade", location_id: 1,
                          properties: { "tags" => %w[weapon edged], "modifiers" => [ { "stat" => "strength", "value" => 2 } ], "effects" => [] }) }
  let(:ring)   { Item.new(name: "ring", subrole: "ring", location_id: 1,
                          properties: { "tags" => %w[jewelry ring], "modifiers" => [], "effects" => [] }) }

  it "you sell for less than you'd buy (the merchant's spread)" do
    buy  = described_class.buy_price(sword,  wealth: "modest", economic_basis: "fishing")
    sell = described_class.sell_price(sword, wealth: "modest", economic_basis: "fishing")
    expect(sell).to be < buy
  end

  describe "wealth" do
    it "a rich town charges more and pays more than a poor one" do
      poor_buy = described_class.buy_price(sword, wealth: "poor", economic_basis: "fishing")
      rich_buy = described_class.buy_price(sword, wealth: "rich", economic_basis: "fishing")
      poor_pay = described_class.sell_price(sword, wealth: "poor", economic_basis: "fishing")
      rich_pay = described_class.sell_price(sword, wealth: "rich", economic_basis: "fishing")
      expect(rich_buy).to be > poor_buy
      expect(rich_pay).to be > poor_pay
    end
  end

  describe "supply/demand by basis" do
    it "weapons are cheaper to buy where they're produced (mining) than where imported (fishing)" do
      mining  = described_class.buy_price(sword, wealth: "modest", economic_basis: "mining")
      fishing = described_class.buy_price(sword, wealth: "modest", economic_basis: "fishing")
      expect(mining).to be < fishing
    end

    it "a town that lacks the good pays more for it on sale" do
      to_fishing = described_class.sell_price(sword, wealth: "modest", economic_basis: "fishing")  # scarce → pays more
      to_mining  = described_class.sell_price(sword, wealth: "modest", economic_basis: "mining")   # abundant → pays less
      expect(to_fishing).to be > to_mining
    end

    it "basis has no effect on a category the table doesn't map (jewelry everywhere imported)" do
      a = described_class.buy_price(ring, wealth: "modest", economic_basis: "mining")
      b = described_class.buy_price(ring, wealth: "modest", economic_basis: "fishing")
      expect(a).to eq(b)
    end
  end

  it "never prices below 1" do
    junk = Item.new(name: "junk", subrole: "t", location_id: 1, properties: { "tags" => [], "modifiers" => [], "effects" => [] })
    expect(described_class.sell_price(junk, wealth: "poor", economic_basis: "mining")).to be >= 1
  end
end
