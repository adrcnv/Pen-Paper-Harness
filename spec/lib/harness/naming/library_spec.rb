require "rails_helper"

RSpec.describe Harness::Naming::Library do
  before { described_class.reload! }

  it "loads at least the four seed cultures shipped with MVP" do
    ids = described_class.all.map { |c| c["id"] }.sort
    expect(ids).to include("anglish", "sklavian", "nord", "myrr")
  end

  it "find returns the culture by id" do
    expect(described_class.find("nord")["id"]).to eq("nord")
  end

  it "find returns nil for unknown id" do
    expect(described_class.find("not_a_culture")).to be_nil
  end

  it "weighted_pick returns one of the loaded cultures" do
    culture = described_class.weighted_pick(rng: Random.new(0))
    expect(described_class.all).to include(culture)
  end

  it "default is deterministic (first alphabetically)" do
    expect(described_class.default["id"]).to eq("anglish")
  end

  it "validates each culture's given pool is non-empty" do
    described_class.all.each do |c|
      expect(c["given"]).to be_an(Array)
      expect(c["given"]).not_to be_empty
      expect(c["given"]).to all(be_a(String))
    end
  end

  it "requires non-empty, disjoint gendered given pools" do
    described_class.all.each do |c|
      expect(c["given_male"]).to be_an(Array).and(be_present)
      expect(c["given_female"]).to be_an(Array).and(be_present)
      expect(c["given_male"] & c["given_female"]).to be_empty,
        "#{c['id']}: gendered pools overlap"
    end
  end

  it "derives `given` as the union of the gendered pools" do
    described_class.all.each do |c|
      expect(c["given"]).to match_array(c["given_male"] + c["given_female"])
    end
  end

  it "rejects a culture whose gendered pools overlap" do
    bad = Tempfile.new([ "overlap_culture", ".yml" ])
    bad.write({
      "id" => "ovl", "weight" => 1,
      "given_male" => [ "Sasha" ], "given_female" => [ "Sasha" ], "family" => [],
      "place_prefix" => [ "Oak" ], "place_suffix" => [ "haven" ], "kingdom_suffix" => [ "Reach" ]
    }.to_yaml)
    bad.flush
    stub_const("Harness::Naming::Library::LIBRARY_DIR", Pathname.new(File.dirname(bad.path)))
    described_class.reload!
    expect { described_class.all }.to raise_error(described_class::InvalidLibrary, /disjoint/)
  ensure
    bad&.close
    bad&.unlink
    stub_const("Harness::Naming::Library::LIBRARY_DIR", Rails.root.join("lib/harness/naming/cultures"))
    described_class.reload!
  end

  it "validates each culture's place-name morphology pools" do
    described_class.all.each do |c|
      %w[place_prefix place_suffix kingdom_suffix].each do |pool|
        expect(c[pool]).to be_an(Array).and(be_present), "#{c['id']}: #{pool}"
        expect(c[pool]).to all(be_a(String))
      end
    end
  end

  it "rejects a culture missing the place-name pools" do
    bad = Tempfile.new([ "no_place_culture", ".yml" ])
    bad.write({
      "id" => "npl", "weight" => 1,
      "given_male" => [ "Garrick" ], "given_female" => [ "Hilde" ], "family" => []
      # no place_prefix / place_suffix / kingdom_suffix
    }.to_yaml)
    bad.flush
    stub_const("Harness::Naming::Library::LIBRARY_DIR", Pathname.new(File.dirname(bad.path)))
    described_class.reload!
    expect { described_class.all }.to raise_error(described_class::InvalidLibrary, /place_prefix/)
  ensure
    bad&.close
    bad&.unlink
    stub_const("Harness::Naming::Library::LIBRARY_DIR", Rails.root.join("lib/harness/naming/cultures"))
    described_class.reload!
  end

  it "validates each culture's family pool is an array of strings" do
    described_class.all.each do |c|
      expect(c["family"]).to be_an(Array)
      expect(c["family"]).to all(be_a(String))
    end
  end

  it "rejects malformed YAML at load time" do
    bad = Tempfile.new([ "bad_culture", ".yml" ])
    bad.write({ "id" => "x" }.to_yaml)  # missing weight/given_male/given_female/family
    bad.flush

    stub_const("Harness::Naming::Library::LIBRARY_DIR", Pathname.new(File.dirname(bad.path)))
    described_class.reload!
    expect { described_class.all }.to raise_error(described_class::InvalidLibrary)
  ensure
    bad&.close
    bad&.unlink
    stub_const("Harness::Naming::Library::LIBRARY_DIR", Rails.root.join("lib/harness/naming/cultures"))
    described_class.reload!
  end
end
