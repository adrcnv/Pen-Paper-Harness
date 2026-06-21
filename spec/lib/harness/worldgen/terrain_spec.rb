require "rails_helper"

RSpec.describe Harness::Worldgen::Terrain do
  let(:geo) { Harness::Worldgen::Geography.generate(seed: 1234, size: 100) }

  # A fake geography so each classification branch can be exercised in isolation,
  # rather than hunting for a real point that happens to hit it.
  Fake = Struct.new(:sea_level, :elev, :sea, :coastal, :riverside, :moist, keyword_init: true) do
    def sea_level = self[:sea_level] || 0.34
    def elevation(_x, _y) = elev
    def sea?(_x, _y) = sea
    def coastal?(_x, _y) = coastal
    def riverside?(_x, _y) = riverside
    def moisture(_x, _y) = moist
  end

  def classify(**attrs)
    described_class.at(geo: Fake.new(**attrs), x: 0.0, y: 0.0)
  end

  describe ".at over a real geography" do
    it "returns only known enum values, never nil" do
      (0..40).each do |i|
        (0..40).each do |j|
          t = described_class.at(geo: geo, x: i * 2.5, y: j * 2.5)
          expect(described_class::ALL).to include(t), "got #{t.inspect}"
        end
      end
    end

    it "classifies open water as sea" do
      expect(described_class.at(geo: geo, x: 0.5, y: 50.0)).to eq(:sea)
    end

    it "produces a varied landscape (more than one land type)" do
      kinds = []
      (0..40).each do |i|
        (0..40).each do |j|
          t = described_class.at(geo: geo, x: i * 2.5, y: j * 2.5)
          kinds << t unless t == :sea
        end
      end
      expect(kinds.uniq.size).to be >= 3
    end
  end

  describe "branch coverage on a controlled geography" do
    it "sea short-circuits everything" do
      expect(classify(sea: true, elev: 0.9, coastal: true, moist: 0.9)).to eq(:sea)
    end

    it "peak elevation → mountain" do
      expect(classify(elev: 0.97, moist: 0.9)).to eq(:mountain)
    end

    it "high elevation → crags" do
      expect(classify(elev: 0.9, moist: 0.9)).to eq(:crags)
    end

    it "coast beats inland classification at low and upland tiers" do
      expect(classify(elev: 0.4,  coastal: true, moist: 0.1)).to eq(:coastal) # low
      expect(classify(elev: 0.7,  coastal: true, moist: 0.1)).to eq(:coastal) # upland
    end

    it "low + riverside + wet → marsh; + dry/moderate → floodplain" do
      expect(classify(elev: 0.4, riverside: true, moist: 0.9)).to eq(:marsh)
      expect(classify(elev: 0.4, riverside: true, moist: 0.2)).to eq(:floodplain)
    end

    it "low flatland by moisture: wet→marsh, moderate→forest_lowland, dry→grassland" do
      expect(classify(elev: 0.4, moist: 0.9)).to eq(:marsh)
      expect(classify(elev: 0.4, moist: 0.5)).to eq(:forest_lowland)
      expect(classify(elev: 0.4, moist: 0.1)).to eq(:grassland)
    end

    it "upland riverside → river_valley" do
      expect(classify(elev: 0.7, riverside: true, moist: 0.5)).to eq(:river_valley)
    end

    it "upland by moisture: wet→forest_upland, moderate→moor, dry→grassland" do
      expect(classify(elev: 0.7, moist: 0.9)).to eq(:forest_upland)
      expect(classify(elev: 0.7, moist: 0.5)).to eq(:moor)
      expect(classify(elev: 0.7, moist: 0.1)).to eq(:grassland)
    end
  end

  describe "lookup tables" do
    it "has habitability and cost for every land type plus sea" do
      (described_class::LAND + [ described_class::SEA ]).each do |t|
        expect(described_class::HABITABILITY).to have_key(t), "habitability missing #{t}"
        expect(described_class::COST).to have_key(t), "cost missing #{t}"
      end
    end

    it "rates fertile/watered ground more habitable than peaks" do
      expect(described_class.habitability(:floodplain)).to be > described_class.habitability(:mountain)
      expect(described_class.habitability(:coastal)).to be > described_class.habitability(:marsh)
    end

    it "costs rough terrain more to cross than open ground" do
      expect(described_class.cost_multiplier(:mountain)).to be > described_class.cost_multiplier(:grassland)
      expect(described_class.cost_multiplier(:crags)).to be > described_class.cost_multiplier(:coastal)
    end
  end
end
