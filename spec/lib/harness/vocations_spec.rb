require "rails_helper"

RSpec.describe Harness::Vocations do
  describe ".all" do
    it "includes every manifest building trade" do
      expect(described_class.all).to include(*Harness::Settlement::Manifest.all_subroles)
    end

    it "includes the non-building extras" do
      expect(described_class.all).to include("bandit", "hermit", "pilgrim")
    end

    it "is a flat list of unique strings" do
      all = described_class.all
      expect(all).to all(be_a(String))
      expect(all.uniq).to eq(all)
    end
  end

  describe ".valid?" do
    it "accepts an exact manifest trade" do
      expect(described_class.valid?("smith")).to be(true)
      expect(described_class.valid?("clerk")).to be(true)
    end

    it "accepts an extras vocation" do
      expect(described_class.valid?("bandit")).to be(true)
    end

    it "rejects a place-relative role (the anti-pattern the enum forbids)" do
      expect(described_class.valid?("patron")).to be(false)
      expect(described_class.valid?("customer")).to be(false)
    end

    it "rejects free-text near-misses (exact match only, no fuzzing)" do
      expect(described_class.valid?("fisherman")).to be(false) # canonical is "fisher"
      expect(described_class.valid?("municipal clerk")).to be(false)
    end

    it "rejects non-strings" do
      expect(described_class.valid?(nil)).to be(false)
      expect(described_class.valid?(:smith)).to be(false)
    end
  end
end
