require "rails_helper"
require "stringio"

RSpec.describe Harness::CharacterCreation do
  def with_io(input_lines)
    io  = StringIO.new(input_lines.join("\n") + "\n")
    out = StringIO.new
    [ io, out ]
  end

  describe ".run end-to-end" do
    it "runs the roll path: name → roll → accept → class" do
      io, out = with_io([
        "Aelin",   # name
        "1",       # method = roll
        "a",       # accept rolled stats
        "1"        # class = fighter
      ])
      result = described_class.run(io: io, out: out, rng: Random.new(42))
      expect(result[:name]).to eq("Aelin")
      expect(result[:character_class]).to eq("fighter")
      expect(result[:stats].keys).to contain_exactly(:strength, :dexterity, :constitution, :intelligence, :wisdom, :charisma)
      expect(result[:stats].values).to all(be_between(2, 20))  # 2d10 range
    end

    it "runs the distribute path: name → distribute → 60 points → class" do
      io, out = with_io([
        "Marn",
        "2",       # method = distribute
        "10", "10", "10", "10", "10",  # auto-balances last to 10
        "4"        # class = mage (index 4 in: fighter, rogue, ranger, mage, sorcerer, cleric)
      ])
      result = described_class.run(io: io, out: out)
      expect(result[:name]).to eq("Marn")
      expect(result[:character_class]).to eq("mage")
      expect(result[:stats].values.sum).to eq(60)
      expect(result[:stats].values).to all(be_between(6, 15))
    end

    it "defaults name to Hero on empty input" do
      io, out = with_io([
        "",        # empty name
        "1", "a",  # roll, accept
        "1"        # fighter
      ])
      result = described_class.run(io: io, out: out, rng: Random.new(1))
      expect(result[:name]).to eq("Hero")
    end
  end

  describe ".roll_stats" do
    it "produces 2d10 values per stat" do
      io, out = with_io([ "a" ])  # accept immediately
      stats = described_class.roll_stats(io, out, rng: Random.new(7))
      expect(stats.values).to all(be_between(2, 20))
    end

    it "rerolls a single chosen stat and commits the new value" do
      # Mock rng so we know exactly what comes out.
      rng = Random.new
      values = [
        # initial roll: 6 stats × 2 dice each = 12 calls
        5, 5,  10, 10,  5, 5,  10, 10,  5, 5,  10, 10,
        # reroll for stat #1 (STR): 2 more dice
        9, 9
      ]
      allow(rng).to receive(:rand).with(1..10).and_return(*values)

      io, out = with_io([
        "r",   # reroll
        "1"    # reroll STR
      ])
      stats = described_class.roll_stats(io, out, rng: rng)
      expect(stats[:strength]).to eq(18)  # 9+9 reroll
      expect(stats[:dexterity]).to eq(20) # 10+10
    end
  end

  describe ".distribute_stats" do
    it "auto-balances the final stat to consume remaining points" do
      io, out = with_io([ "10", "10", "10", "10", "10" ])
      stats = described_class.distribute_stats(io, out)
      expect(stats.values.sum).to eq(60)
      expect(stats.values).to all(eq(10))
    end

    it "rejects values outside DISTRIBUTE_MIN..DISTRIBUTE_MAX and reprompts" do
      io, out = with_io([
        "100",   # too high
        "0",     # too low
        "abc",   # not a number
        "10",    # accepted
        "10", "10", "10", "10"
      ])
      stats = described_class.distribute_stats(io, out)
      expect(stats[:strength]).to eq(10)
      expect(out.string).to match(/enter an integer/)
    end

    it "rejects a value at the LAST numbered stat that would leave too little for the auto-balanced final stat" do
      # First four stats spend 40 (10 each), leaving 20 for the last two stats.
      # 5th stat (the last prompted one) = 15 would leave 5 for the auto-balanced
      # 6th stat — but 5 < DISTRIBUTE_MIN (6). Should reprompt with "too little".
      io, out = with_io([
        "10", "10", "10", "10",
        "15",  # rejected: leaves 5 for the auto-balanced final stat
        "13"   # accepted: leaves 7
                # 6th auto-balances to 7
      ])
      stats = described_class.distribute_stats(io, out)
      expect(stats.values.sum).to eq(60)
      expect(out.string).to match(/leaves too little/)
    end
  end

  describe ".prompt_class" do
    it "returns the class name corresponding to the picked number" do
      io, out = with_io([ "3" ])
      cls = described_class.prompt_class(io, out)
      expect(cls).to eq(described_class::CLASSES[2])
    end

    it "reprompts on out-of-range pick" do
      io, out = with_io([ "99", "abc", "1" ])
      cls = described_class.prompt_class(io, out)
      expect(cls).to eq(described_class::CLASSES[0])
      expect(out.string).to match(/enter a number/)
    end
  end
end
