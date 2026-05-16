require "rails_helper"

RSpec.describe Harness::Scenarios::Roller do
  before { described_class.reload! }

  describe "loading the genesis table" do
    it "loads without error and exposes nothing_interesting at high weight" do
      rows = described_class.load("genesis")
      ids  = rows.map { |r| r["id"] }
      expect(ids).to include("nothing_interesting")
      nothing = rows.find { |r| r["id"] == "nothing_interesting" }
      expect(nothing["weight"]).to be > 50  # the dominant row by design
    end

    it "raises TableMissing for a non-existent table" do
      expect {
        described_class.load("does_not_exist_anywhere")
      }.to raise_error(described_class::TableMissing, /not found/)
    end
  end

  describe "weighted rolling" do
    it "always returns a Result with id" do
      result = described_class.roll(table: "genesis")
      expect(result).to be_a(described_class::Result)
      expect(result.id).to be_a(String)
    end

    it "deterministic with a seeded RNG" do
      a = described_class.roll(table: "genesis", rng: Random.new(42))
      b = described_class.roll(table: "genesis", rng: Random.new(42))
      expect(a.id).to eq(b.id)
      expect(a.prompt_seed).to eq(b.prompt_seed)
    end

    it "honors the weight distribution at scale" do
      rng = Random.new(1234)
      results = 10_000.times.map { described_class.roll(table: "genesis", rng: rng).id }
      nothing_share = results.count("nothing_interesting").to_f / results.size
      # Designed at 90/100. Allow ±0.03 for sampling jitter at N=10k.
      expect(nothing_share).to be_within(0.03).of(0.90)
    end
  end

  describe "context filtering via requires" do
    let(:table_path) { Harness::Scenarios::Roller::TABLES_DIR.join("test_filtering.yml") }

    before do
      File.write(table_path, <<~YAML)
        - id: anywhere
          weight: 50
          prompt_seed: null
        - id: lowland_only
          weight: 50
          requires: { biome: lowland }
          prompt_seed: "SCENARIO: lowland thing"
      YAML
      described_class.reload!
    end

    after { File.delete(table_path) if File.exist?(table_path) }

    it "excludes ineligible rows from the roll pool" do
      rng = Random.new(99)
      ids = 200.times.map { described_class.roll(table: "test_filtering", context: { biome: "highland" }, rng: rng).id }
      expect(ids).to all(eq("anywhere"))
    end

    it "includes rows whose requires match the context" do
      rng = Random.new(99)
      ids = 200.times.map { described_class.roll(table: "test_filtering", context: { biome: "lowland" }, rng: rng).id }
      expect(ids.uniq).to contain_exactly("anywhere", "lowland_only")
    end

    it "raises NoEligibleRow if context excludes every row" do
      File.write(table_path, <<~YAML)
        - id: lowland_only
          weight: 1
          requires: { biome: lowland }
          prompt_seed: "x"
      YAML
      described_class.reload!
      expect {
        described_class.roll(table: "test_filtering", context: { biome: "highland" })
      }.to raise_error(described_class::NoEligibleRow)
    end
  end

  describe "validation" do
    let(:table_path) { Harness::Scenarios::Roller::TABLES_DIR.join("test_invalid.yml") }
    after { File.delete(table_path) if File.exist?(table_path) }

    it "rejects rows missing id" do
      File.write(table_path, "- weight: 1\n  prompt_seed: x\n")
      described_class.reload!
      expect { described_class.load("test_invalid") }.to raise_error(described_class::TableMissing, /missing id/)
    end

    it "rejects rows with negative weight (zero is allowed: entry kept around but never selected)" do
      File.write(table_path, "- id: foo\n  weight: -1\n  prompt_seed: x\n")
      described_class.reload!
      expect { described_class.load("test_invalid") }.to raise_error(described_class::TableMissing, /missing weight/)
    end

    it "accepts rows with weight=0 as a way to disable an entry without deleting it" do
      File.write(table_path, "- id: foo\n  weight: 0\n  prompt_seed: x\n- id: bar\n  weight: 1\n  prompt_seed: y\n")
      described_class.reload!
      expect { described_class.load("test_invalid") }.not_to raise_error
      # Weight-0 entry is never picked.
      results = 100.times.map { described_class.roll(table: "test_invalid").id }
      expect(results.uniq).to eq([ "bar" ])
    end

    it "rejects duplicate ids" do
      File.write(table_path, "- id: foo\n  weight: 1\n  prompt_seed: a\n- id: foo\n  weight: 1\n  prompt_seed: b\n")
      described_class.reload!
      expect { described_class.load("test_invalid") }.to raise_error(described_class::TableMissing, /duplicate id=foo/)
    end
  end
end
