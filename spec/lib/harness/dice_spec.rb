require "rails_helper"

RSpec.describe Harness::Dice do
  describe ".stat_mod" do
    it "follows D&D 5e modifier convention" do
      expect(described_class.stat_mod(10)).to eq(0)
      expect(described_class.stat_mod(11)).to eq(0)
      expect(described_class.stat_mod(12)).to eq(1)
      expect(described_class.stat_mod(14)).to eq(2)
      expect(described_class.stat_mod(18)).to eq(4)
      expect(described_class.stat_mod(8)).to eq(-1)
      expect(described_class.stat_mod(3)).to eq(-4)
    end
  end

  describe ".check — unopposed (DC-based)" do
    # Use seeded RNG: first call to rand(1..20) with seed 42 is deterministic.
    def seeded(seed = 42)
      Random.new(seed)
    end

    it "succeeds when d20 + modifier >= DC" do
      # seed 42 → first roll is deterministic; use a huge modifier to guarantee success
      out = described_class.check(actor_stat: 18, difficulty: "easy", rng: seeded)
      expect(out.result).to eq("success").or eq("critical_success")
    end

    it "treats 'meet DC' as success" do
      # Force the roll via custom rng: always returns 1-20 predictably
      rng = FakeRng.new([ 14 ])  # raw roll 14
      # actor_stat 11 → mod 0; total = 14. DC moderate = 15.
      # Slightly below DC → failure
      out = described_class.check(actor_stat: 11, difficulty: "moderate", rng: rng)
      expect(out.result).to eq("failure")

      # Now try actor_stat 13 → mod 1; total = 15. Meets DC.
      out = described_class.check(actor_stat: 13, difficulty: "moderate", rng: FakeRng.new([ 14 ]))
      expect(out.result).to eq("success")
    end

    it "recognizes critical_success on raw 20" do
      out = described_class.check(actor_stat: 3, difficulty: "very_hard", rng: FakeRng.new([ 20 ]))
      expect(out.result).to eq("critical_success")
      expect(out.critical).to be(true)
    end

    it "recognizes critical_failure on raw 1" do
      out = described_class.check(actor_stat: 18, difficulty: "trivial", rng: FakeRng.new([ 1 ]))
      expect(out.result).to eq("critical_failure")
      expect(out.critical).to be(true)
    end

    it "applies difficulty tiers from the DC table" do
      # roll 10, mod 0 (stat 10) → total 10
      rng = FakeRng.new([ 10 ])
      expect(described_class.check(actor_stat: 10, difficulty: "trivial",  rng: rng).result).to eq("success")
      expect(described_class.check(actor_stat: 10, difficulty: "easy",     rng: FakeRng.new([ 10 ])).result).to eq("success")
      expect(described_class.check(actor_stat: 10, difficulty: "moderate", rng: FakeRng.new([ 10 ])).result).to eq("failure")
      expect(described_class.check(actor_stat: 10, difficulty: "hard",     rng: FakeRng.new([ 10 ])).result).to eq("failure")
      expect(described_class.check(actor_stat: 10, difficulty: "very_hard",rng: FakeRng.new([ 10 ])).result).to eq("failure")
    end

    it "applies a roll modifier" do
      # stat 10 → mod 0; roll 10 → total 10. DC moderate 15 → fail.
      # With roll_modifier 5 → total 15 → success (meet-or-beat).
      rng = FakeRng.new([ 10 ])
      out = described_class.check(actor_stat: 10, difficulty: "moderate", roll_modifier: 5, rng: rng)
      expect(out.result).to eq("success")
    end

    it "margin 'decisive' when diff >= 10" do
      # stat 10, mod 0, roll 20 is crit — use 19 to dodge crit
      # Actually raw 20 is always crit. Let me use roll 18 with big stat bonus.
      # stat 18, mod 4, roll 18 → total 22 vs DC 10 (easy) → diff 12 → decisive
      out = described_class.check(actor_stat: 18, difficulty: "easy", rng: FakeRng.new([ 18 ]))
      expect(out.margin).to eq("decisive")
    end

    it "margin 'narrow' when |diff| < 5" do
      # stat 11 (mod 0), roll 14 → total 14 vs moderate DC 15 → diff -1 → narrow
      out = described_class.check(actor_stat: 11, difficulty: "moderate", rng: FakeRng.new([ 14 ]))
      expect(out.margin).to eq("narrow")
    end
  end

  describe ".check — opposed" do
    it "tie goes to the defender" do
      # both stat 10 (mod 0), both roll 15 → tie → actor fails
      out = described_class.check(actor_stat: 10, target_stat: 10, rng: FakeRng.new([ 15, 15 ]))
      expect(out.result).to eq("failure")
    end

    it "actor wins when actor_total > target_total" do
      out = described_class.check(actor_stat: 14, target_stat: 10, rng: FakeRng.new([ 15, 15 ]))
      # actor: 15 + 2 = 17; target: 15 + 0 = 15; actor wins by 2
      expect(out.result).to eq("success")
      expect(out.margin).to eq("narrow")
    end

    it "critical_success overrides opposed comparison" do
      # actor nat 20, even if target would beat them on total
      out = described_class.check(actor_stat: 3, target_stat: 18, rng: FakeRng.new([ 20, 20 ]))
      expect(out.result).to eq("critical_success")
    end

    it "critical_failure overrides opposed comparison" do
      out = described_class.check(actor_stat: 18, target_stat: 3, rng: FakeRng.new([ 1, 1 ]))
      expect(out.result).to eq("critical_failure")
    end
  end

  # Tiny deterministic RNG: returns values in order from a scripted list.
  class FakeRng
    def initialize(values)
      @values = values.dup
    end
    def rand(range)
      @values.shift
    end
  end
end
