require "rails_helper"

RSpec.describe Harness::Character::XP do
  let(:city) { Location.create!(name: "Saltmere") }

  let(:player) {
    Player.create!(
      name: "Hero", location: city, character_class: "fighter", level: 1,
      strength: 14, dexterity: 12, constitution: 14,
      intelligence: 10, wisdom: 10, charisma: 10,
      max_hp: 11, current_hp: 8, xp: 0,
      abilities: []
    )
  }

  describe ".threshold_for" do
    it "level 1 threshold is 0 (start state)" do
      expect(described_class.threshold_for(1)).to eq(0)
    end

    it "level 2 threshold is 100" do
      expect(described_class.threshold_for(2)).to eq(100)
    end

    it "level 5 threshold is 1000" do
      expect(described_class.threshold_for(5)).to eq(1000)
    end

    it "scales quadratically — level 10 = 4500, level 20 = 19000" do
      expect(described_class.threshold_for(10)).to eq(4500)
      expect(described_class.threshold_for(20)).to eq(19000)
    end

    it "treats level 0 as 0 threshold (defensive)" do
      expect(described_class.threshold_for(0)).to eq(0)
    end
  end

  describe ".for_check" do
    it "prices by difficulty tier, paying nothing for trivial/easy" do
      expect(described_class.for_check(difficulty: "trivial")).to eq(0)
      expect(described_class.for_check(difficulty: "easy")).to eq(0)
      expect(described_class.for_check(difficulty: "moderate")).to eq(5)
      expect(described_class.for_check(difficulty: "hard")).to eq(15)
      expect(described_class.for_check(difficulty: "very_hard")).to eq(30)
    end

    it "adds the clever bonus from the situational modifier, clamped to +5" do
      expect(described_class.for_check(difficulty: "moderate", situational_modifier: 3)).to eq(5 + 9)
      expect(described_class.for_check(difficulty: "hard", situational_modifier: 9)).to eq(15 + 15)
      expect(described_class.for_check(difficulty: "hard", situational_modifier: -2)).to eq(15)
    end

    it "pays no clever bonus when the base tier pays nothing" do
      expect(described_class.for_check(difficulty: "easy", situational_modifier: 5)).to eq(0)
    end

    it "pays the flat opposed rate for beating a live opponent's roll" do
      expect(described_class.for_check(difficulty: "moderate", opposed: true)).to eq(15)
    end
  end

  describe ".for_kill" do
    it "killing equal level: full base XP" do
      expect(described_class.for_kill(killer_level: 5, victim_level: 5)).to eq(250)
    end

    it "killing 2-4 levels above: 1.5× base" do
      expect(described_class.for_kill(killer_level: 5, victim_level: 7)).to eq(525)
    end

    it "killing 5+ levels above: 2.0× base" do
      expect(described_class.for_kill(killer_level: 5, victim_level: 10)).to eq(1000)
    end

    it "killing 1 level below: 0.5× base" do
      expect(described_class.for_kill(killer_level: 5, victim_level: 4)).to eq(100)
    end

    it "killing 3-5 levels below: 0.25× base" do
      expect(described_class.for_kill(killer_level: 10, victim_level: 7)).to eq(87)
    end

    it "killing 6+ levels below: 0.1× base — far below your weight" do
      expect(described_class.for_kill(killer_level: 10, victim_level: 1)).to eq(5)
    end

    it "always at least 1 XP per kill (symbolic floor)" do
      expect(described_class.for_kill(killer_level: 50, victim_level: 1)).to be >= 1
    end
  end

  describe ".award!" do
    it "adds XP without leveling when below next threshold" do
      result = described_class.award!(player, 50)
      player.reload
      expect(player.xp).to eq(50)
      expect(player.level).to eq(1)
      expect(result[:gained]).to eq(50)
      expect(result[:levels_gained]).to eq(0)
      expect(result[:next_threshold]).to eq(100)
    end

    it "auto-levels up when crossing threshold (player picks deferred via pending_ability_picks)" do
      result = described_class.award!(player, 100, rng: Random.new(1))
      player.reload
      expect(player.level).to eq(2)
      expect(result[:levels_gained]).to eq(1)
      expect(result[:new_level]).to eq(2)
      # Player level-ups DEFER ability picks for interactive selection.
      # abilities stays the size it was; pending counter is incremented.
      expect(player.abilities.size).to eq(0)
      expect(player.properties["pending_ability_picks"]).to eq(1)
      expect(result[:abilities_gained]).to eq([])
    end

    it "multi-level player gain accumulates pending picks" do
      result = described_class.award!(player, 1500, rng: Random.new(1))
      player.reload
      expect(player.level).to be >= 5
      expect(player.properties["pending_ability_picks"]).to eq(result[:levels_gained])
    end

    it "level-up restores current_hp to new max" do
      player.update!(current_hp: 1)  # nearly dead
      described_class.award!(player, 100, rng: Random.new(1))
      player.reload
      expect(player.current_hp).to eq(player.max_hp)
      expect(player.current_hp).to be > 1
    end

    it "multi-level gain in one award (huge kill)" do
      # 1 → 5 needs 1000 XP cumulative. 1500 should land somewhere in 5-6.
      result = described_class.award!(player, 1500, rng: Random.new(1))
      player.reload
      expect(player.level).to be >= 5
      expect(result[:levels_gained]).to be >= 4
    end

    it "no-op for zero or negative awards" do
      result = described_class.award!(player, 0)
      expect(result[:levels_gained]).to eq(0)
      expect(player.reload.xp).to eq(0)
    end

    it "grants new ability on levelup; doesn't duplicate existing ones" do
      # Fighter level 2 has 2 eligible entries (heavy_strike, shield_up at min_level 1).
      # Both already owned → grant returns []. Level still bumps.
      heavy = Harness::Abilities::Library.find("heavy_strike")
      shield = Harness::Abilities::Library.find("shield_up")
      player.update!(abilities: [ heavy, shield ])

      result = described_class.award!(player, 100, rng: Random.new(1))
      player.reload
      expect(player.level).to eq(2)
      # No new ability (eligible level-1 pool is exhausted at 2 entries)
      # — only sweeping_blow at min_level 3 would unlock at level 3.
      expect(result[:abilities_gained]).to be_empty
    end
  end
end
