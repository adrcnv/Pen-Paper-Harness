require "rails_helper"

RSpec.describe Harness::Quests::Library do
  before { described_class.reload! }

  it "loads at least the two seed archetypes shipped with MVP" do
    ids = described_class.all.map { |a| a["id"] }.sort
    expect(ids).to include("missing_courier", "wronged_neighbor")
  end

  it "filters by city_tags — empty city_tags archetypes fit anywhere" do
    out = described_class.for_city_tags(%w[port])
    expect(out.map { |a| a["id"] }).to include("missing_courier", "wronged_neighbor")
  end

  it "excludes archetypes whose city_tags don't overlap" do
    out = described_class.for_city_tags(%w[highland])
    ids = out.map { |a| a["id"] }
    expect(ids).to include("wronged_neighbor")           # city_tags: []
    expect(ids).not_to include("missing_courier")        # port / mercantile only
  end

  it "weighted_pick returns nil for empty pool" do
    expect(described_class.weighted_pick([])).to be_nil
  end

  it "weighted_pick returns one of the candidates" do
    pick = described_class.weighted_pick(described_class.all, rng: Random.new(42))
    expect(described_class.all).to include(pick)
  end

  it "validates YAML at load time and aborts on malformed entries" do
    bad = Tempfile.new([ "bad_archetype", ".yml" ])
    bad.write({ "id" => "x" }.to_yaml)  # missing all other required fields
    bad.flush

    stub_const("Harness::Quests::Library::LIBRARY_DIR", Pathname.new(File.dirname(bad.path)))
    described_class.reload!
    expect { described_class.all }.to raise_error(described_class::InvalidLibrary)
  ensure
    bad&.close
    bad&.unlink
    # restore + reload original library before next test runs
    stub_const("Harness::Quests::Library::LIBRARY_DIR", Rails.root.join("lib/harness/quests/library"))
    described_class.reload!
  end
end
