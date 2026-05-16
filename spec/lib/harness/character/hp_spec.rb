require "rails_helper"

RSpec.describe Harness::Character::HP do
  let(:city) { Location.create!(name: "Saltmere") }

  describe ".compute_max" do
    it "scales by level + class hit_die + CON SCORE baseline + CON modifier" do
      # fighter d10, level 5, CON 14 (mod +2):
      # 10 + 14 (full CON score) + ceil(5.5) × 4 + 2 × 5 = 10 + 14 + 24 + 10 = 58
      hp = described_class.compute_max(character_class: "fighter", level: 5, constitution: 14)
      expect(hp).to eq(58)
    end

    it "level 1 fighter with CON 12 = die + CON score + mod" do
      hp = described_class.compute_max(character_class: "fighter", level: 1, constitution: 12)
      expect(hp).to eq(23)  # 10 + 12 + 1
    end

    it "mage d6, level 3, CON 10 — CON score baseline still applies" do
      # 6 + 10 + ceil(3.5) × 2 + 0 × 3 = 6 + 10 + 8 = 24
      hp = described_class.compute_max(character_class: "mage", level: 3, constitution: 10)
      expect(hp).to eq(24)
    end

    it "commoner d6, level 1, CON 10 — fragile but not paper-thin" do
      hp = described_class.compute_max(character_class: "commoner", level: 1, constitution: 10)
      expect(hp).to eq(16)  # 6 + 10
    end

    it "negative CON modifier subtracts per level (CON score still adds at base)" do
      # fighter d10, level 4, CON 6 (mod -2): 10 + 6 + 6×3 + (-2)×4 = 10 + 6 + 18 - 8 = 26
      hp = described_class.compute_max(character_class: "fighter", level: 4, constitution: 6)
      expect(hp).to eq(26)
    end

    it "level 0 returns 0 (defensive)" do
      expect(described_class.compute_max(character_class: "fighter", level: 0, constitution: 10)).to eq(0)
    end

    it "the slope per level is unchanged (intercept shift only)" do
      # Going from level N to N+1 adds (die_avg + con_mod). Pure D&D.
      l1 = described_class.compute_max(character_class: "fighter", level: 1, constitution: 14)
      l2 = described_class.compute_max(character_class: "fighter", level: 2, constitution: 14)
      l5 = described_class.compute_max(character_class: "fighter", level: 5, constitution: 14)
      die_avg = 6  # ceil((10+1)/2)
      con_mod = 2
      expect(l2 - l1).to eq(die_avg + con_mod)
      expect(l5 - l1).to eq(4 * (die_avg + con_mod))
    end
  end

  describe ".apply!" do
    it "writes max_hp + current_hp to the character" do
      npc = Npc.create!(name: "Marek", subrole: "captain", location: city,
                        character_class: "fighter", level: 5, constitution: 14)
      described_class.apply!(npc)
      npc.reload
      expect(npc.max_hp).to eq(58)
      expect(npc.current_hp).to eq(58)
    end

    it "leaves current_hp unchanged when reset_current: false" do
      npc = Npc.create!(name: "Wounded", subrole: "fighter", location: city,
                        character_class: "fighter", level: 5, constitution: 14,
                        max_hp: 58, current_hp: 12)
      described_class.apply!(npc, reset_current: false)
      npc.reload
      expect(npc.max_hp).to eq(58)  # recomputed
      expect(npc.current_hp).to eq(12)  # left alone
    end
  end
end
