require "rails_helper"

RSpec.describe Harness::Settlement::Layout do
  def city_with(profile)
    Location.create!(
      name: "Saltmere", x: 10.0, y: 20.0, biome: "lowland",
      properties: { "kind" => "city" }.merge(profile)
    )
  end

  let(:fishing_town) do
    city_with("terrain" => "coastal", "coastal" => true,
              "economic_basis" => "fishing", "size" => "town", "wealth" => "modest")
  end

  it "creates manifest sublocations as child Location stubs" do
    created = described_class.lay_out!(city: fishing_town, rng: Random.new(1))
    expect(created).not_to be_empty
    children = Location.where(parent_id: fishing_town.id)
    expect(children.pluck(:name)).to include(*created.map(&:name))
    expect(children.map { |c| c.properties["manifest_key"] }).to include("docks", "tavern", "smithy")
  end

  it "stamps trade + kind on each stub so the Materializer can populate it" do
    described_class.lay_out!(city: fishing_town, rng: Random.new(1))
    docks = Location.where(parent_id: fishing_town.id).find { |c| c.properties["manifest_key"] == "docks" }
    expect(docks.properties["kind"]).to eq("sublocation")
    expect(docks.properties["trade"]).to eq("fisher")
    expect(docks.description).to be_present
  end

  it "is idempotent — a second run creates nothing and re-entry doesn't duplicate" do
    described_class.lay_out!(city: fishing_town, rng: Random.new(1))
    count_after_first = Location.where(parent_id: fishing_town.id).count
    second = described_class.lay_out!(city: fishing_town.reload, rng: Random.new(1))
    expect(second).to be_empty
    expect(Location.where(parent_id: fishing_town.id).count).to eq(count_after_first)
  end

  it "does not recreate a wing the player/quest already made (manifest_key guard)" do
    # Pre-existing smithy (e.g. quest-spawned) with the same manifest_key.
    Location.create!(name: "the Old Forge", parent_id: fishing_town.id,
                     properties: { "kind" => "sublocation", "manifest_key" => "smithy" })
    described_class.lay_out!(city: fishing_town, rng: Random.new(1))
    smithies = Location.where(parent_id: fishing_town.id).select { |c| c.properties["manifest_key"] == "smithy" }
    expect(smithies.size).to eq(1)
    expect(smithies.first.name).to eq("the Old Forge")
  end

  it "no-ops for a location without an economic profile (fixture / pre-geography)" do
    bare = Location.create!(name: "Nowhere", x: 1.0, y: 1.0, properties: { "kind" => "city" })
    expect(described_class.lay_out!(city: bare)).to be_empty
    expect(Location.where(parent_id: bare.id)).to be_empty
  end

  it "a mining town lays out a minehead, never docks" do
    town = city_with("terrain" => "crags", "economic_basis" => "mining", "size" => "town", "wealth" => "comfortable")
    described_class.lay_out!(city: town, rng: Random.new(2))
    keys = Location.where(parent_id: town.id).map { |c| c.properties["manifest_key"] }
    expect(keys).to include("minehead")
    expect(keys).not_to include("docks")
  end
end
