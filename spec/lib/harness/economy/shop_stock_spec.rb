require "rails_helper"

RSpec.describe Harness::Economy::ShopStock do
  let(:city) {
    Location.create!(name: "Brackton", x: 1.0, y: 1.0, biome: "lowland",
                     properties: { "kind" => "city", "economic_basis" => "mining", "size" => "town", "wealth" => "comfortable" })
  }
  let(:smithy) {
    Location.create!(name: "the Smithy", parent: city,
                     properties: { "kind" => "sublocation", "trade" => "smith", "shop" => %w[weapons armor] })
  }

  it "anchors category-appropriate wares to the shop, flagged for_sale" do
    created = described_class.stock!(smithy, rng: Random.new(1))
    expect(created).not_to be_empty
    created.each do |item|
      expect(item.location_id).to eq(smithy.id)
      expect(item.character_id).to be_nil
      expect(item.properties["for_sale"]).to be(true)
      expect(item.properties["tags"]).to satisfy { |t| (t & %w[weapon armor]).any? }
    end
  end

  it "scales count with size + wealth" do
    small = Location.create!(name: "Forge", parent:
              Location.create!(name: "Hamlet", x: 2, y: 2, properties: { "size" => "hamlet", "wealth" => "poor" }),
              properties: { "shop" => %w[weapons] })
    big   = smithy
    small_n = described_class.stock!(small, rng: Random.new(5)).size
    big_n   = described_class.stock!(big,   rng: Random.new(5)).size
    expect(big_n).to be > small_n
  end

  it "is idempotent — re-entry doesn't restock" do
    described_class.stock!(smithy, rng: Random.new(1))
    n = Item.where(location_id: smithy.id).count
    second = described_class.stock!(smithy.reload, rng: Random.new(1))
    expect(second).to be_empty
    expect(Item.where(location_id: smithy.id).count).to eq(n)
  end

  it "no-ops for a non-shop location" do
    plain = Location.create!(name: "the Well", parent: city, properties: { "kind" => "sublocation" })
    expect(described_class.stock!(plain)).to be_empty
    expect(Item.where(location_id: plain.id)).to be_empty
  end
end
