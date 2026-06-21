require "rails_helper"

RSpec.describe Harness::Settlement::Profile do
  describe ".roll" do
    it "returns the three axes with values from the canonical sets" do
      p = described_class.roll(terrain: "grassland", rng: Random.new(1))
      expect(described_class::BASES).to include(p["economic_basis"])
      expect(described_class::SIZES).to include(p["size"])
      expect(described_class::WEALTH_TIERS).to include(p["wealth"])
    end

    it "is deterministic given the rng seed" do
      a = described_class.roll(terrain: "crags", coastal: false, riverside: true, rng: Random.new(7))
      b = described_class.roll(terrain: "crags", coastal: false, riverside: true, rng: Random.new(7))
      expect(a).to eq(b)
    end

    it "handles unknown terrain via the default weighting" do
      p = described_class.roll(terrain: nil, rng: Random.new(2))
      expect(described_class::BASES).to include(p["economic_basis"])
    end
  end

  describe "economic_basis is terrain-shaped" do
    # Roll many times; the basis distribution should reflect the terrain.
    def basis_histogram(terrain:, coastal: false, riverside: false, n: 400)
      Array.new(n) { |i| described_class.roll_basis(terrain, coastal, riverside, Random.new(i)) }
        .tally
    end

    it "crags produce mining/quarrying, never fishing" do
      h = basis_histogram(terrain: "crags")
      expect(h.keys).to include("mining")
      expect(h["fishing"].to_i).to eq(0)
    end

    it "forest_upland produces the long-tail charcoal/logging trades" do
      h = basis_histogram(terrain: "forest_upland")
      expect(h.keys).to include("charcoal").or include("logging")
      expect((h["charcoal"].to_i + h["logging"].to_i)).to be > (h.values.sum / 2)
    end

    it "coastal flag injects fishing/port even on otherwise dry terrain" do
      dry  = basis_histogram(terrain: "grassland", coastal: false)
      wet  = basis_histogram(terrain: "grassland", coastal: true)
      expect(dry["fishing"].to_i).to eq(0)
      expect(wet["fishing"].to_i).to be > 0
    end

    it "riverside flag injects river_trade" do
      land  = basis_histogram(terrain: "grassland", riverside: false)
      river = basis_histogram(terrain: "grassland", riverside: true)
      expect(land["river_trade"].to_i).to eq(0)
      expect(river["river_trade"].to_i).to be > 0
    end
  end

  describe "size + wealth" do
    it "skews small (most settlements are hamlets/villages)" do
      sizes = Array.new(500) { |i| described_class.roll_size("grassland", Random.new(i)) }.tally
      small = sizes["hamlet"].to_i + sizes["village"].to_i
      expect(small).to be > 250
    end

    it "prosperous terrain produces more towns/cities than barren" do
      fertile = Array.new(500) { |i| described_class.roll_size("floodplain", Random.new(i)) }.tally
      barren  = Array.new(500) { |i| described_class.roll_size("mountain",  Random.new(i)) }.tally
      big_fertile = fertile["town"].to_i + fertile["city"].to_i
      big_barren  = barren["town"].to_i + barren["city"].to_i
      expect(big_fertile).to be > big_barren
    end

    it "a trade city trends richer than a charcoal hamlet" do
      rich_runs = Array.new(200) { |i| described_class.roll_wealth("market", "city", Random.new(i)) }
      poor_runs = Array.new(200) { |i| described_class.roll_wealth("charcoal", "hamlet", Random.new(i)) }
      rich_score = rich_runs.count { |w| %w[comfortable rich].include?(w) }
      poor_score = poor_runs.count { |w| %w[comfortable rich].include?(w) }
      expect(rich_score).to be > poor_score
    end
  end
end
