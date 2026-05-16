require "rails_helper"

RSpec.describe Harness::Scene::PendingAppearanceResolver do
  let(:logger)   { Logger.new(IO::NULL) }
  let(:city)     { Location.create!(name: "Saltmere") }
  let(:tavern)   { Location.create!(name: "Tavern", parent: city) }
  let(:warehouse) { Location.create!(name: "Warehouse", parent: city) }
  let(:other_city) { Location.create!(name: "Ironwood") }
  let(:player)   { Player.create!(name: "Hero", location: tavern) }
  let(:guild)    { Faction.create!(name: "Shadow Hand", subrole: "thieves_guild") }

  describe "relocation (existing class-4 actor)" do
    let(:debt_collector) { Npc.create!(name: "Vell", subrole: "merchant", location: other_city) }
    let!(:pa) {
      PendingAppearance.create!(
        target_character: player,
        origin_character: debt_collector,
        actor_character:  debt_collector,
        intent_text:      "wants payment",
        anchor_location:  tavern,
        scope:            "local",
        earliest_at:      500
      )
    }

    it "relocates the named character to the scene location" do
      out = described_class.new(logger: logger).resolve(target_character: player, current_location: tavern, current_game_time: 1000)
      expect(out.size).to eq(1)
      expect(out.first.kind).to eq(:relocated)
      expect(out.first.character).to eq(debt_collector)
      expect(debt_collector.reload.location).to eq(tavern)
    end

    it "writes appearance_intent into the character's properties" do
      described_class.new(logger: logger).resolve(target_character: player, current_location: tavern, current_game_time: 1000)
      expect(debt_collector.reload.properties).to include("appearance_intent" => "wants payment")
    end

    it "marks the appearance resolved at current_game_time" do
      described_class.new(logger: logger).resolve(target_character: player, current_location: tavern, current_game_time: 1000)
      expect(pa.reload.resolved_at).to eq(1000)
    end
  end

  describe "wake (dormant class-4 actor)" do
    # Post-Phase-2: PAs that reference a genesis-spawned dormant historical
    # by actor_character_id. Resolution relocates them and clears dormant.
    let(:korr) { Npc.create!(name: "Korr", subrole: "thieves_guild", location: other_city, properties: { "dormant" => true, "faction_id" => 99 }) }
    let!(:pa) {
      PendingAppearance.create!(
        target_character: player,
        origin_faction:   guild,
        actor_character:  korr,
        intent_text:      "looking for the player",
        anchor_location:  tavern,
        scope:            "local",
        earliest_at:      500
      )
    }

    it "wakes the dormant character, relocating and clearing the flag" do
      out = described_class.new(logger: logger).resolve(target_character: player, current_location: tavern, current_game_time: 1000)
      expect(out.size).to eq(1)
      expect(out.first.kind).to eq(:woke)

      char = out.first.character.reload
      expect(char.name).to eq("Korr")
      expect(char.location).to eq(tavern)
      expect(char.properties).to include("appearance_intent" => "looking for the player")
      expect(char.properties).not_to have_key("dormant")
    end
  end

  describe "faceless spawn (origin_faction, no actor)" do
    let!(:pa) {
      PendingAppearance.create!(
        target_character: player,
        origin_faction:   guild,
        intent_text:      "demands the player visit the captain",
        anchor_location:  tavern,
        scope:            "local",
        earliest_at:      500
      )
    }

    it "spawns a fresh Npc with name derived from faction" do
      out = described_class.new(logger: logger).resolve(target_character: player, current_location: tavern, current_game_time: 1000)
      expect(out.size).to eq(1)
      expect(out.first.kind).to eq(:spawned)
      char = out.first.character
      expect(char.name).to start_with("Shadow Hand emissary")
      expect(char.location).to eq(tavern)
      expect(char.subrole).to eq("thieves_guild")
      expect(char.properties).to include("appearance_intent" => /captain/, "faction_id" => guild.id)
    end

    it "disambiguates names on collision" do
      Npc.create!(name: "Shadow Hand emissary", subrole: "x", location: city)
      out = described_class.new(logger: logger).resolve(target_character: player, current_location: tavern, current_game_time: 1000)
      expect(out.first.character.name).to eq("Shadow Hand emissary (2)")
    end
  end

  describe "scope eligibility" do
    let!(:local_pa) {
      PendingAppearance.create!(target_character: player, origin_faction: guild,
                                intent_text: "x", anchor_location: tavern,
                                scope: "local", earliest_at: 500)
    }

    it "local scope skips when player is at sibling, not anchor" do
      out = described_class.new(logger: logger).resolve(target_character: player, current_location: warehouse, current_game_time: 1000)
      expect(out).to be_empty
      expect(local_pa.reload.resolved_at).to be_nil
    end

    it "city scope fires at sibling under same parent" do
      city_pa = PendingAppearance.create!(target_character: player, origin_faction: guild,
                                          intent_text: "x", anchor_location: tavern,
                                          scope: "city", earliest_at: 500)
      out = described_class.new(logger: logger).resolve(target_character: player, current_location: warehouse, current_game_time: 1000)
      expect(out.size).to eq(1)
      expect(out.first.appearance).to eq(city_pa)
    end

    it "city scope does NOT fire in a different city" do
      PendingAppearance.create!(target_character: player, origin_faction: guild,
                                intent_text: "x", anchor_location: tavern,
                                scope: "city", earliest_at: 500)
      out = described_class.new(logger: logger).resolve(target_character: player, current_location: other_city, current_game_time: 1000)
      expect(out).to be_empty
    end

    it "anywhere scope fires regardless of location, with no anchor needed" do
      anywhere = PendingAppearance.create!(target_character: player, origin_faction: guild,
                                           intent_text: "x", anchor_location: nil,
                                           scope: "anywhere", earliest_at: 500)
      out = described_class.new(logger: logger).resolve(target_character: player, current_location: other_city, current_game_time: 1000)
      expect(out.map(&:appearance)).to include(anywhere)
    end
  end

  describe "filtering" do
    it "skips not-yet-firable appearances" do
      PendingAppearance.create!(target_character: player, origin_faction: guild,
                                intent_text: "x", anchor_location: tavern,
                                scope: "local", earliest_at: 9999)
      out = described_class.new(logger: logger).resolve(target_character: player, current_location: tavern, current_game_time: 1000)
      expect(out).to be_empty
    end

    it "skips already-resolved" do
      PendingAppearance.create!(target_character: player, origin_faction: guild,
                                intent_text: "x", anchor_location: tavern,
                                scope: "local", earliest_at: 500, resolved_at: 600)
      out = described_class.new(logger: logger).resolve(target_character: player, current_location: tavern, current_game_time: 1000)
      expect(out).to be_empty
    end

    it "returns [] when target_character is nil" do
      out = described_class.new(logger: logger).resolve(target_character: nil, current_location: tavern, current_game_time: 1000)
      expect(out).to eq([])
    end
  end

  describe "transactional behavior" do
    it "resolves multiple eligible appearances in one entry" do
      PendingAppearance.create!(target_character: player, origin_faction: guild,
                                intent_text: "first", anchor_location: tavern,
                                scope: "local", earliest_at: 500)
      PendingAppearance.create!(target_character: player, origin_faction: guild,
                                intent_text: "second", anchor_location: tavern,
                                scope: "local", earliest_at: 500)

      out = described_class.new(logger: logger).resolve(target_character: player, current_location: tavern, current_game_time: 1000)
      expect(out.size).to eq(2)
      expect(Npc.where(location: tavern).count).to eq(2)
    end
  end
end
