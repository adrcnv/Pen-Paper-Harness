require "rails_helper"

RSpec.describe Harness::Items::Library do
  before  { described_class.reload! }
  after   { described_class.reload! }

  it "loads all four categories without raising" do
    %w[weapons armor jewelry magical].each do |c|
      expect(described_class.for_category(c)).to be_an(Array)
      expect(described_class.for_category(c)).not_to be_empty
    end
  end

  it "weighted_pick returns an entry from the requested category" do
    100.times do
      pick = described_class.weighted_pick("weapons", rng: Random.new)
      expect(pick).not_to be_nil
      expect(pick["base_tags"]).to include("weapon")
    end
  end

  it "find returns the entry by id" do
    expect(described_class.find("short_blade")["id"]).to eq("short_blade")
    expect(described_class.find("nonexistent")).to be_nil
  end

  it "raises InvalidLibrary when a category is unknown" do
    expect { described_class.for_category("quantum_artifacts") }.to raise_error(described_class::InvalidLibrary)
  end

  it "validates magical effect_pool triggers against TriggerRegistry at boot" do
    # The shipped magical.yml is valid — it must pass cleanly.
    expect { described_class.for_category("magical") }.not_to raise_error
  end
end
