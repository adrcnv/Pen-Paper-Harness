require "rails_helper"

RSpec.describe Harness::Settlement::Scenery do
  let(:town)  { Location.create!(name: "Saltmere") }
  let(:other) { Location.create!(name: "Coldleigh") }

  it "lists one spec per key, each with a gloss, names and a description" do
    expect(described_class.keys).to eq(described_class.keys.uniq)
    described_class.specs.each do |s|
      expect(s.gloss).to be_present
      expect(s.names).not_to be_empty
      expect(s.description).to be_present
    end
  end

  it "mints a kind once per settlement and links it after" do
    loc, minted = described_class.find_or_mint!(settlement: town, key: "alley", rng: Random.new(1))
    expect(minted).to be(true)
    expect(loc.parent).to eq(town)
    expect(loc.properties).to include("scenery_key" => "alley", "kind" => "sublocation")
    expect(described_class.spec("alley").names).to include(loc.name)
    again, minted_again = described_class.find_or_mint!(settlement: town, key: "alley", rng: Random.new(2))
    expect(again).to eq(loc)
    expect(minted_again).to be(false)
  end

  it "keeps settlements apart and refuses an unknown key" do
    a, = described_class.find_or_mint!(settlement: town, key: "shack")
    b, = described_class.find_or_mint!(settlement: other, key: "shack")
    expect(a).not_to eq(b)
    expect(described_class.find_or_mint!(settlement: town, key: "palace")).to be_nil
  end
end
