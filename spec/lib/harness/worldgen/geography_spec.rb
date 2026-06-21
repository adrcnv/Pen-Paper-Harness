require "rails_helper"

RSpec.describe Harness::Worldgen::Geography do
  let(:geo) { described_class.generate(seed: 1234, size: 100) }

  it "is deterministic given the seed (same rivers)" do
    a = described_class.generate(seed: 7, size: 100)
    b = described_class.generate(seed: 7, size: 100)
    expect(a.rivers.map(&:points)).to eq(b.rivers.map(&:points))
  end

  it "completes generation (the continuous walk terminates — no infinite loop)" do
    expect { described_class.generate(seed: 99, size: 100) }.not_to raise_error
  end

  it "sinks the map margins to sea (edge falloff → a coherent coast)" do
    expect(geo.sea?(0.5, 50.0)).to be(true)
    expect(geo.sea?(99.5, 50.0)).to be(true)
  end

  describe "rivers" do
    it "carves at least one, each terminating in the sea or a lake" do
      expect(geo.rivers).not_to be_empty
      geo.rivers.each do |r|
        expect(%i[sea lake]).to include(r.ends_in)
        expect(r.points.size).to be >= 1
      end
    end

    it "flow downhill overall — the mouth is never higher than the source" do
      geo.rivers.each do |r|
        next if r.points.size < 2
        expect(geo.elevation(*r.points.last)).to be <= (geo.elevation(*r.points.first) + 1e-6)
      end
    end

    it "sea-reaching rivers end at an actual sea point" do
      geo.rivers.select { |r| r.ends_in == :sea }.each do |r|
        expect(geo.sea?(*r.mouth)).to be(true)
      end
    end

    it "lakes are the basin endpoints (surfaced separately)" do
      lake_rivers = geo.rivers.select { |r| r.ends_in == :lake }
      expect(geo.lakes).to match_array(lake_rivers.map(&:mouth))
    end
  end

  describe "per-point water queries" do
    it "identifies a non-empty coastline of land points beside the sea" do
      coastal = []
      (0..20).each do |i|
        (0..20).each do |j|
          x = i * 5.0; y = j * 5.0
          coastal << [ x, y ] if geo.coastal?(x, y)
        end
      end
      expect(coastal).not_to be_empty
      coastal.each do |x, y|
        expect(geo.sea?(x, y)).to be(false)                                   # coast is land
        ring_hits_sea = geo.send(:ring, x, y, described_class::COAST_RADIUS).any? { |px, py| geo.sea?(px, py) }
        expect(ring_hits_sea).to be(true)                                     # ...with sea nearby
      end
    end

    it "flags a point on a river as riverside" do
      river   = geo.rivers.max_by { |r| r.points.size }
      land_pt = river.points.find { |x, y| !geo.sea?(x, y) } || river.points.first
      expect(geo.riverside?(*land_pt)).to be(true)
    end

    it "boosts moisture near water and stays in [0,1]" do
      river  = geo.rivers.max_by { |r| r.points.size }
      rx, ry = river.points.find { |x, y| !geo.sea?(x, y) } || river.points.first
      base   = Harness::Worldgen::Noise.new(seed: 1234)
                 .at(rx * described_class::MOIST_SCALE + 1000.0, ry * described_class::MOIST_SCALE + 1000.0)
      m = geo.moisture(rx, ry)
      expect(m).to be >= base          # water proximity only adds wetness
      expect(m).to be_between(0.0, 1.0)
    end
  end
end
