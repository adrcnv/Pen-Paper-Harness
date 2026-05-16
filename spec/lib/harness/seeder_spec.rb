require "rails_helper"

RSpec.describe Harness::Seeder do
  describe "tavern with a barkeep and an event" do
    let!(:world) do
      described_class.build do
        millhaven = location("Millhaven", description: "A small town")
        tavern    = location("The Hilltop Tavern", description: "Warm, smells of malt", parent: millhaven)
        square    = location("Town Square",        description: "Cobblestones and a well",  parent: millhaven)

        shadow_hand = faction("Shadow Hand", subrole: "thieves_guild", reach: "docks")
        maren     = character("Maren", subrole: "barkeep", location: tavern, personality: "cautious", anxiety: 0.3)
        mug         = item("Clay Mug", subrole: "mug", location: tavern)

        event(
          game_time: 1,
          location: tavern,
          participants: { maren => :actor },
          note: "Maren opens the tavern for the evening"
        )
      end
    end

    it "creates locations with parent relations" do
      expect(Location.count).to eq(3)
      tavern = Location.find_by!(name: "The Hilltop Tavern")
      Location.find_by!(name: "Town Square")
      expect(tavern.parent.name).to eq("Millhaven")
    end

    it "creates characters, factions, and items in their own tables" do
      expect(Npc.count).to eq(1)
      expect(Faction.count).to eq(1)
      expect(Item.count).to eq(1)

      maren = Npc.with_subrole("barkeep").first
      expect(maren.name).to eq("Maren")
      expect(maren.properties["personality"]).to eq("cautious")
    end

    it "places characters and items at locations" do
      tavern = Location.find_by!(name: "The Hilltop Tavern")
      expect(Npc.at(tavern.id).pluck(:subrole)).to eq([ "barkeep" ])
      expect(Item.at(tavern.id).pluck(:subrole)).to eq([ "mug" ])
    end

    it "logs an event with a character participant" do
      ev = Event.first
      expect(ev.participants.count).to eq(1)
      expect(ev.event_participants.first.role).to eq("actor")
      expect(ev.details["note"]).to match(/opens the tavern/)
    end

    it "supports json property queries on characters" do
      results = Npc.prop_eq("personality", "cautious")
      expect(results.map(&:name)).to eq([ "Maren" ])
    end
  end
end
