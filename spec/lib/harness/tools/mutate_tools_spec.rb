require "rails_helper"

RSpec.describe "Harness::Tools mutation family" do
  let(:city)    { Location.create!(name: "Saltmere") }
  let(:tavern)  { Location.create!(name: "Tavern", parent: city) }
  let(:warehouse) { Location.create!(name: "Warehouse", parent: city) }
  let(:maren) { Npc.create!(name: "Maren", subrole: "barkeep", location: tavern) }
  let(:context) { Harness::Turn::Context.new(player_location: tavern, game_time: 42) }

  describe Harness::Tools::MutateCharacter do
    describe "column updates" do
      it "renames" do
        result = described_class.new.call({ "character_id" => maren.id, "field" => "name", "value" => "Fartimus" }, context)
        expect(result["old_value"]).to eq("Maren")
        expect(result["new_value"]).to eq("Fartimus")
        expect(maren.reload.name).to eq("Fartimus")
      end

      it "changes subrole" do
        described_class.new.call({ "character_id" => maren.id, "field" => "subrole", "value" => "retired_barkeep" }, context)
        expect(maren.reload.subrole).to eq("retired_barkeep")
      end

      it "updates location_id when location exists" do
        described_class.new.call({ "character_id" => maren.id, "field" => "location_id", "value" => warehouse.id }, context)
        expect(maren.reload.location_id).to eq(warehouse.id)
      end

      it "accepts nil location_id (unplaced)" do
        described_class.new.call({ "character_id" => maren.id, "field" => "location_id", "value" => nil }, context)
        expect(maren.reload.location_id).to be_nil
      end

      it "rejects unknown location_id" do
        result = described_class.new.call({ "character_id" => maren.id, "field" => "location_id", "value" => 99_999 }, context)
        expect(result["error"]).to match(/no location/)
        expect(maren.reload.location).to eq(tavern)
      end

      it "rejects non-integer location_id" do
        result = described_class.new.call({ "character_id" => maren.id, "field" => "location_id", "value" => "Ironwood" }, context)
        expect(result["error"]).to match(/location_id must be integer/)
      end

      it "sets a stat column" do
        described_class.new.call({ "character_id" => maren.id, "field" => "strength", "value" => 14 }, context)
        expect(maren.reload.strength).to eq(14)
      end

      it "clamps stats above the range and flags clamped: true" do
        result = described_class.new.call({ "character_id" => maren.id, "field" => "strength", "value" => 99 }, context)
        expect(result["clamped"]).to be(true)
        expect(result["new_value"]).to eq(30)
        expect(maren.reload.strength).to eq(30)
      end

      it "clamps stats below the range" do
        result = described_class.new.call({ "character_id" => maren.id, "field" => "dexterity", "value" => -5 }, context)
        expect(result["new_value"]).to eq(1)
        expect(result["clamped"]).to be(true)
      end

      it "rejects non-integer stat values" do
        result = described_class.new.call({ "character_id" => maren.id, "field" => "wisdom", "value" => "high" }, context)
        expect(result["error"]).to match(/must be an integer/)
      end

      it "rejects empty name" do
        result = described_class.new.call({ "character_id" => maren.id, "field" => "name", "value" => "   " }, context)
        expect(result["error"]).to match(/name must be/)
      end
    end

    describe "property merges" do
      it "sets a new property key" do
        result = described_class.new.call({ "character_id" => maren.id, "field" => "hp", "value" => 50 }, context)
        expect(result["new_value"]).to eq(50)
        expect(maren.reload.properties).to include("hp" => 50)
      end

      it "updates an existing property key, returning the old value" do
        maren.update!(properties: { "hp" => 50 })
        result = described_class.new.call({ "character_id" => maren.id, "field" => "hp", "value" => 30 }, context)
        expect(result["old_value"]).to eq(50)
        expect(result["new_value"]).to eq(30)
      end

      it "deletes a property key when value is null" do
        maren.update!(properties: { "mood" => "grim", "hp" => 50 })
        described_class.new.call({ "character_id" => maren.id, "field" => "mood", "value" => nil }, context)
        expect(maren.reload.properties).to eq({ "hp" => 50 })
      end
    end

    describe "error paths" do
      it "returns {error:} for unknown character_id" do
        result = described_class.new.call({ "character_id" => 99_999, "field" => "name", "value" => "x" }, context)
        expect(result["error"]).to match(/no character/)
      end

      it "returns {error:} for reserved field 'type'" do
        result = described_class.new.call({ "character_id" => maren.id, "field" => "type", "value" => "Player" }, context)
        expect(result["error"]).to match(/reserved/)
      end

      it "returns {error:} for reserved field 'properties'" do
        result = described_class.new.call({ "character_id" => maren.id, "field" => "properties", "value" => {} }, context)
        expect(result["error"]).to match(/reserved/)
      end

      it "returns {error:} for missing field" do
        result = described_class.new.call({ "character_id" => maren.id }, context)
        expect(result["error"]).to match(/field must be/)
      end
    end

    describe "event logging" do
      it "forward-appends a personal-scope event with the character as subject" do
        expect {
          described_class.new.call({ "character_id" => maren.id, "field" => "name", "value" => "Fartimus" }, context)
        }.to change(Event, :count).by(1)
        expect(context.game_time).to eq(42)

        ev = Event.last
        expect(ev.scope).to eq("personal")
        expect(ev.game_time).to eq(42)
        expect(ev.location).to eq(tavern)
        expect(ev.details["mutation"]).to include(
          "target_type" => "character",
          "target_id"   => maren.id,
          "field"       => "name",
          "old_value"   => "Maren",
          "new_value"   => "Fartimus"
        )
        expect(ev.event_participants.first.character).to eq(maren)
        expect(ev.event_participants.first.role).to eq("subject")
      end

      it "does NOT log an event when the mutation fails validation" do
        expect {
          described_class.new.call({ "character_id" => maren.id, "field" => "location_id", "value" => 99_999 }, context)
        }.not_to change(Event, :count)
      end
    end
  end

  describe Harness::Tools::MutateFaction do
    let(:guild) { Faction.create!(name: "Shadow Hand", subrole: "thieves_guild", is_kingdom: false, properties: { "disposition" => "cagey" }) }

    it "renames" do
      result = described_class.new.call({ "faction_id" => guild.id, "field" => "name", "value" => "The Shadow Hand" }, context)
      expect(result["new_value"]).to eq("The Shadow Hand")
      expect(guild.reload.name).to eq("The Shadow Hand")
    end

    it "flips is_kingdom" do
      described_class.new.call({ "faction_id" => guild.id, "field" => "is_kingdom", "value" => true }, context)
      expect(guild.reload.is_kingdom).to be(true)
    end

    it "rejects non-boolean is_kingdom" do
      result = described_class.new.call({ "faction_id" => guild.id, "field" => "is_kingdom", "value" => "yes" }, context)
      expect(result["error"]).to match(/is_kingdom must be boolean/)
    end

    it "changes subrole" do
      described_class.new.call({ "faction_id" => guild.id, "field" => "subrole", "value" => "kingdom" }, context)
      expect(guild.reload.subrole).to eq("kingdom")
    end

    it "merges a property key" do
      described_class.new.call({ "faction_id" => guild.id, "field" => "reach", "value" => "citywide" }, context)
      expect(guild.reload.properties).to include("reach" => "citywide", "disposition" => "cagey")
    end

    it "deletes a property key with null" do
      described_class.new.call({ "faction_id" => guild.id, "field" => "disposition", "value" => nil }, context)
      expect(guild.reload.properties).not_to have_key("disposition")
    end

    it "returns {error:} for unknown faction" do
      result = described_class.new.call({ "faction_id" => 99_999, "field" => "name", "value" => "X" }, context)
      expect(result["error"]).to match(/no faction/)
    end

    it "logs an event with empty participants and null location" do
      expect {
        described_class.new.call({ "faction_id" => guild.id, "field" => "is_kingdom", "value" => true }, context)
      }.not_to change { context.game_time }
      ev = Event.last
      expect(ev.scope).to eq("personal")
      expect(ev.location).to be_nil
      expect(ev.event_participants).to be_empty
      expect(ev.game_time).to eq(42)
      expect(ev.details["mutation"]).to include(
        "target_type" => "faction",
        "target_name" => "Shadow Hand",
        "field"       => "is_kingdom",
        "new_value"   => true
      )
    end
  end

  describe Harness::Tools::MutateItem do
    let(:mug) { Item.create!(name: "Mug", subrole: "drinkware", location: tavern) }

    describe "pickup/drop semantics" do
      it "pickup: setting character_id clears location_id" do
        described_class.new.call({ "item_id" => mug.id, "field" => "character_id", "value" => maren.id }, context)
        mug.reload
        expect(mug.character_id).to eq(maren.id)
        expect(mug.location_id).to be_nil
      end

      it "drop: setting location_id clears character_id" do
        mug.update!(location_id: nil, character: maren)  # first, be in inventory
        described_class.new.call({ "item_id" => mug.id, "field" => "location_id", "value" => warehouse.id }, context)
        mug.reload
        expect(mug.location_id).to eq(warehouse.id)
        expect(mug.character_id).to be_nil
      end

      it "rejects unknown character_id" do
        result = described_class.new.call({ "item_id" => mug.id, "field" => "character_id", "value" => 99_999 }, context)
        expect(result["error"]).to match(/no character/)
      end

      it "rejects unknown location_id" do
        result = described_class.new.call({ "item_id" => mug.id, "field" => "location_id", "value" => 99_999 }, context)
        expect(result["error"]).to match(/no location/)
      end

      it "rejects null character_id (destruction is a separate operation)" do
        result = described_class.new.call({ "item_id" => mug.id, "field" => "character_id", "value" => nil }, context)
        expect(result["error"]).to match(/must be a non-null integer/)
      end

      it "rejects null location_id" do
        result = described_class.new.call({ "item_id" => mug.id, "field" => "location_id", "value" => nil }, context)
        expect(result["error"]).to match(/must be a non-null integer/)
      end
    end

    describe "other columns" do
      it "renames" do
        described_class.new.call({ "item_id" => mug.id, "field" => "name", "value" => "Chipped Mug" }, context)
        expect(mug.reload.name).to eq("Chipped Mug")
      end

      it "changes subrole" do
        described_class.new.call({ "item_id" => mug.id, "field" => "subrole", "value" => "weapon" }, context)
        expect(mug.reload.subrole).to eq("weapon")
      end
    end

    describe "property merges" do
      it "sets and deletes" do
        described_class.new.call({ "item_id" => mug.id, "field" => "condition", "value" => "chipped" }, context)
        expect(mug.reload.properties).to include("condition" => "chipped")

        described_class.new.call({ "item_id" => mug.id, "field" => "condition", "value" => nil }, context)
        expect(mug.reload.properties).not_to have_key("condition")
      end
    end

    describe "event logging" do
      it "logs event at the holder's location when item picked up, with holder as participant" do
        maren # instantiate
        expect {
          described_class.new.call({ "item_id" => mug.id, "field" => "character_id", "value" => maren.id }, context)
        }.not_to change { context.game_time }
        ev = Event.last
        expect(ev.location).to eq(tavern)  # maren's location
        expect(ev.game_time).to eq(42)
        expect(ev.event_participants.first.character).to eq(maren)
        expect(ev.event_participants.first.role).to eq("holder")
        expect(ev.details["mutation"]["target_type"]).to eq("item")
        expect(ev.details["mutation"]["target_name"]).to eq("Mug")
      end

      it "logs event at the item's new location when dropped, with no participants" do
        mug.update!(location_id: nil, character: maren)
        described_class.new.call({ "item_id" => mug.id, "field" => "location_id", "value" => warehouse.id }, context)
        ev = Event.last
        expect(ev.location).to eq(warehouse)
        expect(ev.event_participants).to be_empty
      end
    end
  end
end
