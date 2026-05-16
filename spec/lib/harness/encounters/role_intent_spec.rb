require "rails_helper"

RSpec.describe Harness::Encounters::RoleIntent do
  describe ".for" do
    it "returns a hash with subrole_bias + role_intent for each known type" do
      %w[combat discovery social].each do |t|
        entry = described_class.for(t)
        expect(entry).to be_a(Hash)
        expect(entry[:subrole_bias]).to be_an(Array).and(be_present)
        expect(entry[:role_intent]).to be_a(String).and(be_present)
      end
    end

    it "returns nil for an unknown type" do
      expect(described_class.for("ritual")).to be_nil
      expect(described_class.for(nil)).to be_nil
    end
  end

  describe ".sample_subrole" do
    it "returns a value from the subrole_bias for the type" do
      pool = described_class::INTENT["combat"][:subrole_bias]
      pick = described_class.sample_subrole("combat", rng: Random.new(0))
      expect(pool).to include(pick)
    end

    it "returns nil for unknown types" do
      expect(described_class.sample_subrole("ritual")).to be_nil
    end
  end
end
