require "rails_helper"

RSpec.describe Harness::Abilities::DiceFormula do
  describe ".parse" do
    it "parses a single dice term" do
      out = described_class.parse("2d6")
      expect(out.size).to eq(1)
      expect(out.first.count).to eq(2)
      expect(out.first.sides).to eq(6)
    end

    it "parses a sum of dice terms" do
      out = described_class.parse("1d8+1d4")
      expect(out.size).to eq(2)
      expect(out.map(&:count)).to eq([ 1, 1 ])
      expect(out.map(&:sides)).to eq([ 8, 4 ])
    end

    it "parses a flat bonus" do
      out = described_class.parse("2d6+3")
      expect(out.size).to eq(2)
      expect(out.last.flat).to eq(3)
      expect(out.last.count).to eq(0)
    end

    it "raises ParseError on unrecognized chunks" do
      expect { described_class.parse("2d6-1d4") }.to raise_error(described_class::ParseError)
      expect { described_class.parse("(1d6+2)") }.to raise_error(described_class::ParseError)
    end
  end

  describe ".roll" do
    it "produces a result inside the formula's range" do
      100.times do
        result = described_class.roll("2d6", rng: Random.new)
        expect(result).to be_between(2, 12).inclusive
      end
    end

    it "includes the flat bonus" do
      result = described_class.roll("0+5+0", rng: Random.new)  # only flat
      expect(result).to eq(5)
    end

    it "is deterministic with a seeded RNG" do
      a = described_class.roll("3d6+2", rng: Random.new(42))
      b = described_class.roll("3d6+2", rng: Random.new(42))
      expect(a).to eq(b)
    end
  end

  describe ".roll_ability" do
    let(:ability) {
      {
        "min_level"        => 7,
        "damage_dice"      => "2d6",
        "damage_per_level" => "1d6"
      }
    }

    it "rolls only the base at exactly min_level" do
      result = described_class.roll_ability(ability: ability, caster_level: 7, rng: Random.new(1))
      expect(result).to be_between(2, 12).inclusive  # 2d6 only
    end

    it "adds damage_per_level rolls per level beyond min_level" do
      # at level 12 = 7 base + 5 extra rolls of 1d6 = 2d6 + 5d6 = 7d6
      result = described_class.roll_ability(ability: ability, caster_level: 12, rng: Random.new(1))
      expect(result).to be_between(7, 42).inclusive
    end

    it "treats levels below min_level as if at min_level (no negative scaling)" do
      a = described_class.roll_ability(ability: ability, caster_level: 1, rng: Random.new(1))
      b = described_class.roll_ability(ability: ability, caster_level: 7, rng: Random.new(1))
      # Same base, different RNG draws → just check both are in 2d6 range
      expect(a).to be_between(2, 12).inclusive
      expect(b).to be_between(2, 12).inclusive
    end

    it "handles missing damage_dice (e.g. buff abilities) returning 0" do
      buff = { "min_level" => 1, "damage_dice" => nil, "damage_per_level" => nil }
      expect(described_class.roll_ability(ability: buff, caster_level: 5, rng: Random.new)).to eq(0)
    end

    it "handles missing damage_per_level (no scaling)" do
      flat = { "min_level" => 1, "damage_dice" => "1d6", "damage_per_level" => nil }
      result = described_class.roll_ability(ability: flat, caster_level: 20, rng: Random.new)
      expect(result).to be_between(1, 6).inclusive
    end
  end
end
