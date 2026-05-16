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

  it "validates each culture's family pool is an array of strings" do
    described_class.all.each do |c|
      expect(c["family"]).to be_an(Array)
      expect(c["family"]).to all(be_a(String))
    end
  end

  it "rejects malformed YAML at load time" do
    bad = Tempfile.new([ "bad_culture", ".yml" ])
    bad.write({ "id" => "x" }.to_yaml)  # missing weight/given/family
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
