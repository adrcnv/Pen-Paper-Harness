require "rails_helper"

RSpec.describe Harness::Scene::Routine do
  def npc(subrole)
    Npc.new(name: "X", subrole: subrole)
  end

  NOON    = 12 * 60
  MORNING = 8 * 60
  EVENING = 19 * 60
  NIGHT   = 2 * 60

  describe ".state" do
    it "a day-trade works morning+day and is free of an evening" do
      smith = npc("smith")
      expect(described_class.state(smith, MORNING)).to eq(:working)
      expect(described_class.state(smith, NOON)).to eq(:working)
      expect(described_class.state(smith, EVENING)).to eq(:free)
    end

    it "a barkeep works day+evening and is free of a morning" do
      barkeep = npc("barkeep")
      expect(described_class.state(barkeep, MORNING)).to eq(:free)
      expect(described_class.state(barkeep, EVENING)).to eq(:working)
    end

    it "an itinerant (wanderer) holds no post — free whenever awake" do
      expect(described_class.state(npc("wanderer"), NOON)).to eq(:free)
    end

    it "a free-text stray subrole falls into the default day-trade bucket" do
      expect(described_class.state(npc("municipal clerk"), NOON)).to eq(:working)
      expect(described_class.state(npc("municipal clerk"), EVENING)).to eq(:free)
    end

    it "everyone is off at night" do
      expect(described_class.state(npc("smith"), NIGHT)).to eq(:off)
      expect(described_class.state(npc("wanderer"), NIGHT)).to eq(:off)
    end
  end

  describe ".free? / .awake? (draw gates)" do
    it "a nil clock disables the routine gate entirely" do
      expect(described_class.free?(npc("smith"), nil)).to be(true)
      expect(described_class.awake?(npc("smith"), nil)).to be(true)
    end

    it "an on-shift NPC is not free but is awake (still pullable as a traveler)" do
      smith = npc("smith")
      expect(described_class.free?(smith, NOON)).to be(false)
      expect(described_class.awake?(smith, NOON)).to be(true)
    end
  end
end
