require "rails_helper"

RSpec.describe Harness::Scene::VenueHours do
  def loc(name) = Location.new(name: name)

  describe ".kind (name-keyword classification)" do
    it "classifies taverns, trades, inns, and shrines" do
      expect(described_class.kind(loc("the Alehouse"))).to eq("tavern")
      expect(described_class.kind(loc("the Common Room"))).to eq("tavern")
      expect(described_class.kind(loc("the Public House"))).to eq("tavern")
      expect(described_class.kind(loc("the Mill"))).to eq("trade")
      expect(described_class.kind(loc("the Mending Shed"))).to eq("trade")
      expect(described_class.kind(loc("the Docks"))).to eq("trade")
      expect(described_class.kind(loc("Dockside Inn"))).to eq("inn")
      expect(described_class.kind(loc("Wayside Shrine"))).to eq("shrine")
    end

    it "matches whole words only (the Landing is a dock, not an inn)" do
      expect(described_class.kind(loc("the Landing"))).to eq("trade")
      expect(described_class.kind(loc("the Spinnery"))).to be_nil
    end

    it "has no opinion on unclassifiable places" do
      expect(described_class.kind(loc("the Moot Hall"))).to be_nil
      expect(described_class.kind(nil)).to be_nil
    end
  end

  describe ".open? / .closed?" do
    it "a tavern is shut of a morning only — staffed day, evening, and NIGHT" do
      tavern = loc("the Alehouse")
      expect(described_class.open?(tavern, :morning)).to be(false)
      expect(described_class.open?(tavern, :day)).to be(true)
      expect(described_class.open?(tavern, :evening)).to be(true)
      expect(described_class.open?(tavern, :night)).to be(true)
    end

    it "a trade venue works morning+day and shuts of an evening" do
      mill = loc("the Mill")
      expect(described_class.open?(mill, :morning)).to be(true)
      expect(described_class.closed?(mill, :evening)).to be(true)
    end

    it "an unclassified venue is always open (no mysterious emptying)" do
      expect(described_class.open?(loc("the Moot Hall"), :morning)).to be(true)
      expect(described_class.open?(loc("the Moot Hall"), :evening)).to be(true)
    end
  end

  describe ".barred? (the door policy)" do
    it "a shut trade venue bars its door; taverns NEVER bar" do
      expect(described_class.barred?(loc("the Mill"), :evening)).to be(true)
      expect(described_class.barred?(loc("the Mill"), :night)).to be(true)
      expect(described_class.barred?(loc("the Mill"), :day)).to be(false)
      expect(described_class.barred?(loc("the Alehouse"), :morning)).to be(false)
      expect(described_class.barred?(loc("the Alehouse"), :night)).to be(false)
    end

    it "unclassified places never bar" do
      expect(described_class.barred?(loc("the Moot Hall"), :night)).to be(false)
    end
  end

  describe ".residents_present? (who is home and awake)" do
    it "classified venues follow their hours, including tavern nights" do
      expect(described_class.residents_present?(loc("the Alehouse"), :night)).to be(true)
      expect(described_class.residents_present?(loc("the Alehouse"), :morning)).to be(false)
      expect(described_class.residents_present?(loc("the Mill"), :evening)).to be(false)
    end

    it "everywhere else follows the day/night rhythm" do
      expect(described_class.residents_present?(loc("the Moot Hall"), :day)).to be(true)
      expect(described_class.residents_present?(loc("the Moot Hall"), :night)).to be(false)
    end
  end
end
