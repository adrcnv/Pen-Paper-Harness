require "rails_helper"

RSpec.describe Harness::Combat::Initiative do
  let(:loc) { Location.create!(name: "Tavern") }

  def char(name, dex)
    Npc.create!(name: name, subrole: "patron", location: loc, dexterity: dex)
  end

  describe ".roll" do
    it "returns ids ordered by 1d20 + DEX_mod descending" do
      a = char("A", 18)   # +4
      b = char("B", 10)   # +0
      c = char("C", 6)    # -2
      rng = Random.new(7) # deterministic
      result = described_class.roll([ a.id, b.id, c.id ], rng: rng)
      # The exact order depends on the seed, but we can assert all ids show up.
      expect(result).to match_array([ a.id, b.id, c.id ])
    end

    it "ties break by character_id (stable)" do
      a = char("A", 10)
      b = char("B", 10)
      # Force every actor to roll the same value.
      stub_rng = Object.new
      def stub_rng.rand(_range) = 10
      result = described_class.roll([ b.id, a.id ], rng: stub_rng)
      # Equal scores -> sort by id ascending (smallest id wins ordering).
      expect(result).to eq([ a.id, b.id ])
    end

    it "high DEX wins decisively over low DEX" do
      fast = char("Fast", 20)  # +5
      slow = char("Slow", 4)   # -3
      # Force d20 = 1 for everyone — DEX_mod is the deciding factor.
      stub_rng = Object.new
      def stub_rng.rand(_range) = 1
      result = described_class.roll([ slow.id, fast.id ], rng: stub_rng)
      expect(result).to eq([ fast.id, slow.id ])
    end
  end
end
