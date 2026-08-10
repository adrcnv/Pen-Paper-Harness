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

  describe "venue-hours posts (home at a classified sublocation)" do
    let(:city)     { Location.create!(name: "Saltmere") }
    let(:alehouse) { Location.create!(name: "the Alehouse", parent: city) }

    it "derives the shift from the venue's hours, not the subrole block" do
      pot_boy = Npc.create!(name: "Pot Boy", subrole: "labourer", location: alehouse, home_location: alehouse)
      expect(described_class.state(pot_boy, MORNING)).to eq(:off)     # night-shift keeper sleeps through the closed block
      expect(described_class.state(pot_boy, EVENING)).to eq(:working) # subrole block says :free
      expect(described_class.state(pot_boy, NIGHT)).to eq(:working)   # taverns are staffed at night
    end

    it "a day-trade post-holder is off at night and free of an evening" do
      mill   = Location.create!(name: "the Mill", parent: city)
      miller = Npc.create!(name: "Miller", subrole: "miller", location: mill, home_location: mill)
      expect(described_class.state(miller, NOON)).to eq(:working)
      expect(described_class.state(miller, EVENING)).to eq(:free)   # the smith-at-the-pub hour
      expect(described_class.state(miller, NIGHT)).to eq(:off)
    end

    it "falls back to the subrole block for an unclassifiable venue home" do
      hall  = Location.create!(name: "the Moot Hall", parent: city)
      clerk = Npc.create!(name: "Hall Clerk", subrole: "clerk", location: hall, home_location: hall)
      expect(described_class.state(clerk, NOON)).to eq(:working)
      expect(described_class.state(clerk, EVENING)).to eq(:free)
    end

    it "falls back to the subrole block for a root-homed character" do
      smith = Npc.create!(name: "Root Smith", subrole: "smith", location: city, home_location: city)
      expect(described_class.state(smith, NOON)).to eq(:working)
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
