require "rails_helper"

RSpec.describe Harness::Knowledge::Query do
  # Saltmere is the city; Tavern and Docks are sibling sublocations.
  let(:city)   { Location.create!(name: "Saltmere") }
  let(:tavern) { Location.create!(name: "Tavern", parent: city) }
  let(:docks)  { Location.create!(name: "Docks",  parent: city) }

  def npc(attrs = {})
    @n ||= 0; @n += 1
    Npc.create!({ name: "NPC#{@n}", current_hp: 5, max_hp: 5, intelligence: 10, location_id: tavern.id }.merge(attrs))
  end

  def fact(attrs = {})
    Knowledge.create!({ content: "a fact", game_time: 0 }.merge(attrs))
  end

  def contents(result) = result.map(&:content)

  describe "world-general (all-null) facts" do
    it "reach any character, including one with no subrole" do
      fact(content: "the sun rises in the east")
      bare = npc(subrole: nil)
      expect(contents(described_class.for(character: bare))).to include("the sun rises in the east")
    end
  end

  describe "subrole facet" do
    it "matches a character of that exact subrole and excludes others" do
      fact(content: "form 4-B goes to the strongroom", subrole: "clerk")
      expect(contents(described_class.for(character: npc(subrole: "clerk")))).to include("form 4-B goes to the strongroom")
      expect(contents(described_class.for(character: npc(subrole: "fisher")))).not_to include("form 4-B goes to the strongroom")
    end

    it "does not leak a subrole fact to a character with no subrole" do
      fact(content: "clerk lore", subrole: "clerk")
      expect(contents(described_class.for(character: npc(subrole: nil)))).not_to include("clerk lore")
    end
  end

  describe "place facet (ancestry up-chain)" do
    it "surfaces a city-scoped fact to a character in a sublocation of that city" do
      fact(content: "the tithe was repealed", location_id: city.id)
      here = npc(location_id: tavern.id)
      expect(contents(described_class.for(character: here))).to include("the tithe was repealed")
    end

    it "keeps a sublocation-scoped fact from leaking to a sibling sublocation" do
      fact(content: "the harbor is closed", location_id: docks.id)
      at_tavern = npc(location_id: tavern.id)
      at_docks  = npc(location_id: docks.id)
      expect(contents(described_class.for(character: at_tavern))).not_to include("the harbor is closed")
      expect(contents(described_class.for(character: at_docks))).to include("the harbor is closed")
    end

    it "gives a location-less character only world-general facts" do
      fact(content: "world fact")
      fact(content: "city fact", location_id: city.id)
      nowhere = npc(location_id: nil)
      out = contents(described_class.for(character: nowhere))
      expect(out).to include("world fact")
      expect(out).not_to include("city fact")
    end
  end

  describe "min_int facet" do
    it "gates a fact above the character's intelligence" do
      fact(content: "learned lore", min_int: 12)
      expect(contents(described_class.for(character: npc(intelligence: 14)))).to include("learned lore")
      expect(contents(described_class.for(character: npc(intelligence: 8)))).not_to include("learned lore")
    end

    it "gives a character with no intelligence only ungated facts" do
      fact(content: "learned lore", min_int: 12)
      expect(contents(described_class.for(character: npc(intelligence: nil)))).not_to include("learned lore")
    end
  end

  describe "social_class and faction facets" do
    it "gates on social_class" do
      fact(content: "burgher business", social_class: "burgher")
      expect(contents(described_class.for(character: npc(social_class: "burgher")))).to include("burgher business")
      expect(contents(described_class.for(character: npc))).not_to include("burgher business") # default commoner
    end

    it "gates on faction" do
      fact(content: "guild secret", faction: "salters_guild")
      expect(contents(described_class.for(character: npc(faction: "salters_guild")))).to include("guild secret")
      expect(contents(described_class.for(character: npc))).not_to include("guild secret") # default factionless
    end
  end

  describe "supersession" do
    it "excludes non-current facts" do
      fact(content: "stale fact", current: false)
      expect(contents(described_class.for(character: npc))).not_to include("stale fact")
    end
  end

  describe "ranking and limit" do
    it "returns newest-first by game_time (default recency ranker)" do
      fact(content: "older", game_time: 1)
      fact(content: "newer", game_time: 5)
      expect(contents(described_class.for(character: npc))).to eq([ "newer", "older" ])
    end

    it "caps at the limit" do
      3.times { |i| fact(content: "f#{i}", game_time: i) }
      expect(described_class.for(character: npc, limit: 2).size).to eq(2)
    end
  end

  describe "compound gating" do
    it "requires ALL non-null facets to match at once" do
      fact(content: "saltmere clerk lore", subrole: "clerk", location_id: city.id)
      # right subrole, right place → match
      expect(contents(described_class.for(character: npc(subrole: "clerk", location_id: tavern.id)))).to include("saltmere clerk lore")
      # right subrole, wrong place (no location) → no match
      expect(contents(described_class.for(character: npc(subrole: "clerk", location_id: nil)))).not_to include("saltmere clerk lore")
      # wrong subrole, right place → no match
      expect(contents(described_class.for(character: npc(subrole: "fisher", location_id: tavern.id)))).not_to include("saltmere clerk lore")
    end
  end
end
