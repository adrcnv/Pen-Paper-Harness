require "rails_helper"

RSpec.describe Harness::Settlement::Manifest do
  def keys_for(basis:, size:, wealth:, seed: 1)
    described_class.for(economic_basis: basis, size: size, wealth: wealth, rng: Random.new(seed))
      .map(&:key)
  end

  it "returns Spec structs with a chosen name, subrole, and description" do
    spec = described_class.for(economic_basis: "fishing", size: "village", wealth: "modest", rng: Random.new(1)).first
    expect(spec.name).to be_present
    expect(spec.subrole).to be_present
    expect(spec.description).to be_present
  end

  describe "economic_basis shapes the trade-specific sublocations" do
    it "a fishing settlement has docks; never a minehead" do
      keys = keys_for(basis: "fishing", size: "town", wealth: "modest")
      expect(keys).to include("docks")
      expect(keys).not_to include("minehead")
    end

    it "a mining settlement has a minehead; never docks" do
      keys = keys_for(basis: "mining", size: "town", wealth: "modest")
      expect(keys).to include("minehead")
      expect(keys).not_to include("docks")
    end

    it "a charcoal settlement gets the evocative charcoal camp" do
      expect(keys_for(basis: "charcoal", size: "hamlet", wealth: "poor")).to include("charcoal_camp")
    end
  end

  describe "size gates the count" do
    it "a hamlet has fewer sublocations than a city of the same basis" do
      hamlet = keys_for(basis: "fishing", size: "hamlet", wealth: "poor")
      city   = keys_for(basis: "fishing", size: "city",   wealth: "rich")
      expect(city.size).to be > hamlet.size
    end

    it "a hamlet has a tavern + docks but no town-tier garrison/temple" do
      keys = keys_for(basis: "fishing", size: "hamlet", wealth: "poor")
      expect(keys).to include("tavern", "docks")
      expect(keys).not_to include("garrison", "temple")
    end

    it "a town unlocks the size-gated civic buildings" do
      keys = keys_for(basis: "farming", size: "town", wealth: "modest")
      expect(keys).to include("smithy", "garrison", "temple", "moot_hall")
    end
  end

  describe "wealth gates services" do
    it "a poor town has no moneylender; a comfortable one does" do
      poor        = keys_for(basis: "market", size: "town", wealth: "poor")
      comfortable = keys_for(basis: "market", size: "town", wealth: "comfortable")
      expect(poor).not_to include("moneylender")
      expect(comfortable).to include("moneylender")
    end
  end

  it "dedups by key (one tavern even if basis overlaps universal)" do
    keys = keys_for(basis: "market", size: "town", wealth: "rich")
    expect(keys.count("market_square")).to be <= 1
    expect(keys).to eq(keys.uniq)
  end

  it "is deterministic for a given rng seed (stable names)" do
    a = described_class.for(economic_basis: "port", size: "city", wealth: "rich", rng: Random.new(9)).map(&:name)
    b = described_class.for(economic_basis: "port", size: "city", wealth: "rich", rng: Random.new(9)).map(&:name)
    expect(a).to eq(b)
  end
end
