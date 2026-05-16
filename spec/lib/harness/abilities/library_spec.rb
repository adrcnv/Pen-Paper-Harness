require "rails_helper"

RSpec.describe Harness::Abilities::Library do
  it "loads the YAML library without raising" do
    expect { described_class.all }.not_to raise_error
    expect(described_class.all).not_to be_empty
  end

  it "validates each ability against the schema" do
    described_class.all.each do |ability|
      expect(ability["id"]).to be_a(String).and(be_present)
      expect(ability["min_level"]).to be_a(Integer).and(be >= 1)
      expect(ability["classes"]).to be_a(Array).and(be_present)
      expect(described_class::ALLOWED_EFFECT_KINDS).to include(ability["effect_kind"])
      expect(described_class::ALLOWED_RANGES).to include(ability["range"])
      expect(ability["uses_per_rest"]).to be_a(Integer).and(be >= 1)
    end
  end

  it "covers all six ability classes (commoner has no native entries)" do
    classes_used = described_class.all.flat_map { |a| a["classes"] }.uniq
    %w[fighter mage sorcerer cleric rogue ranger].each do |c|
      expect(classes_used).to include(c), "no abilities tagged for class=#{c}"
    end
  end

  it "exposes commoner-eligible abilities (subset of fighter, all min_level <= 3)" do
    commoner_pool = described_class.for_class("commoner")
    expect(commoner_pool).not_to be_empty
    commoner_pool.each do |a|
      expect(a["classes"]).to include("commoner")
      expect(a["min_level"]).to be <= 3, "commoner ability #{a['id']} has min_level=#{a['min_level']} > 3"
    end
  end

  it "spans the full 1-20 level range with at least one ability available at each tier" do
    tiers = [ 1, 3, 7, 12, 17 ]
    tiers.each do |tier|
      reachable = described_class.all.select { |a| a["min_level"] <= tier }
      expect(reachable).not_to be_empty, "no abilities reachable at level #{tier}"
    end
    legendary = described_class.all.select { |a| a["min_level"] >= 17 }
    expect(legendary).not_to be_empty, "no legendary-tier abilities (min_level >= 17)"
  end

  describe ".for_class" do
    it "returns abilities whose classes include the given id" do
      mage_pool = described_class.for_class("mage")
      expect(mage_pool).not_to be_empty
      expect(mage_pool.all? { |a| a["classes"].include?("mage") }).to be(true)
    end

    it "filters by max_level when given" do
      level_3_mages = described_class.for_class("mage", max_level: 3)
      expect(level_3_mages.all? { |a| a["min_level"] <= 3 }).to be(true)
    end
  end

  describe ".classes" do
    it "loads the class roster" do
      ids = described_class.classes.map { |c| c["id"] }
      expect(ids).to match_array(%w[commoner fighter mage sorcerer cleric rogue ranger])
    end

    it "exposes primary_stat per class" do
      expect(described_class.primary_stat("mage")).to eq("intelligence")
      expect(described_class.primary_stat("sorcerer")).to eq("charisma")
      expect(described_class.primary_stat("cleric")).to eq("wisdom")
      expect(described_class.primary_stat("fighter")).to eq("strength")
      expect(described_class.primary_stat("rogue")).to eq("dexterity")
      expect(described_class.primary_stat("ranger")).to eq("dexterity")
      expect(described_class.primary_stat("commoner")).to be_nil
    end
  end

  describe ".stat_for_ability" do
    let(:incineration_blast) { described_class.find("incineration_blast") }  # mage + sorcerer
    let(:heavy_strike)       { described_class.find("heavy_strike") }        # fighter + commoner

    it "uses class primary_stat when ability has no override" do
      expect(described_class.stat_for_ability(ability: incineration_blast, character_class: "mage")).to eq("intelligence")
      expect(described_class.stat_for_ability(ability: incineration_blast, character_class: "sorcerer")).to eq("charisma")
    end

    it "falls back to first class with primary_stat when character class has none (commoner case)" do
      # heavy_strike is shared by [fighter, commoner]; commoner has no primary_stat,
      # so should fall through to fighter's = strength.
      expect(described_class.stat_for_ability(ability: heavy_strike, character_class: "commoner")).to eq("strength")
    end

    it "respects an explicit stat override on the ability" do
      override = incineration_blast.merge("stat" => "wisdom")
      expect(described_class.stat_for_ability(ability: override, character_class: "mage")).to eq("wisdom")
    end
  end
end
