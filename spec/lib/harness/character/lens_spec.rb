require "rails_helper"

RSpec.describe Harness::Character::Lens do
  describe ".roll" do
    it "returns a value from the DISTRIBUTION keyset" do
      100.times do
        rolled = described_class.roll
        expect(described_class::VALID).to include(rolled)
      end
    end

    it "is deterministic given a fixed rng seed" do
      rng_a = Random.new(42)
      rng_b = Random.new(42)
      expect(described_class.roll(rng: rng_a)).to eq(described_class.roll(rng: rng_b))
    end

    it "skews toward 'balanced' as the most-frequent outcome" do
      rng    = Random.new(1)
      counts = Hash.new(0)
      10_000.times { counts[described_class.roll(rng: rng)] += 1 }
      # `balanced` weights at 50 of 100 → ~half. Allow generous tolerance.
      balanced_share = counts["balanced"].to_f / 10_000
      expect(balanced_share).to be_between(0.40, 0.60)
    end
  end

  describe ".apply!" do
    let(:loc) { Location.create!(name: "T") }
    let(:npc) { Npc.create!(name: "X", location: loc) }

    it "writes a lens to properties" do
      described_class.apply!(npc, rng: Random.new(0))
      npc.reload
      expect(described_class::VALID).to include(npc.properties["lens"])
    end

    it "is idempotent — does not overwrite an existing lens" do
      npc.update!(properties: { "lens" => "cynical" })
      described_class.apply!(npc, rng: Random.new(0))
      expect(npc.reload.properties["lens"]).to eq("cynical")
    end

    it "overwrites an unrecognized lens value with a fresh roll" do
      npc.update!(properties: { "lens" => "wat" })
      described_class.apply!(npc, rng: Random.new(0))
      expect(described_class::VALID).to include(npc.reload.properties["lens"])
    end

    it "preserves other property keys" do
      npc.update!(properties: { "personality" => "stoic", "mood" => "tired" })
      described_class.apply!(npc, rng: Random.new(0))
      props = npc.reload.properties
      expect(props["personality"]).to eq("stoic")
      expect(props["mood"]).to eq("tired")
      expect(described_class::VALID).to include(props["lens"])
    end
  end
end
