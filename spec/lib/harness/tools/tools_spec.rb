require "rails_helper"

RSpec.describe "Harness::Tools" do
  let(:city)   { Location.create!(name: "Saltmere") }
  let(:tavern) { Location.create!(name: "Tavern", parent: city) }
  let(:forest) { Location.create!(name: "Forest") }
  let(:context) { Harness::Turn::Context.new(player_location: tavern) }

  describe Harness::Tools::QueryScene do
    it "returns snapshot of the current scene" do
      maren = Npc.create!(name: "Maren", subrole: "barkeep", location: tavern)
      result = described_class.new.call({}, context)
      expect(result["location"]["name"]).to eq("Tavern")
      expect(result["present_characters"].first).to include("id" => maren.id, "name" => "Maren")
    end

    it "omits internal_state when no active scene is set" do
      Npc.create!(name: "Maren", subrole: "barkeep", location: tavern)
      result = described_class.new.call({}, context)
      expect(result["present_characters"].first).not_to have_key("internal_state")
    end

    it "surfaces internal_state from the active scene when present" do
      maren = Npc.create!(name: "Maren", subrole: "barkeep", location: tavern)
      snapshot = Harness::Scene::Assembler.for(location: tavern)
      context.active_scene = Harness::Scene::Active.new(
        location: tavern, snapshot: snapshot, narrations: [],
        internal_state: { maren.id => "Maren is in a foul mood after a long morning." }
      )
      result = described_class.new.call({}, context)
      entry = result["present_characters"].find { |c| c["id"] == maren.id }
      expect(entry["internal_state"]).to eq("Maren is in a foul mood after a long morning.")
    end

    describe "agenda on present_characters" do
      it "exposes the agenda text on the NPC who has one" do
        maren = Npc.create!(name: "Maren", subrole: "barkeep", location: tavern)
        snapshot = Harness::Scene::Assembler.for(location: tavern)
        context.active_scene = Harness::Scene::Active.new(
          location: tavern, snapshot: snapshot, narrations: [],
          internal_state: { maren.id => "..." },
          agendas:        { maren.id => "wants to ask the player about the docks; her brother went missing last week" },
          extras: []
        )
        result = described_class.new.call({}, context)
        entry = result["present_characters"].find { |c| c["id"] == maren.id }
        expect(entry["agenda"]["text"]).to match(/docks/)
        expect(entry["agenda"]["push_now"]).to be(false)
      end

      it "omits the agenda key on NPCs without one" do
        maren = Npc.create!(name: "Maren", subrole: "barkeep", location: tavern)
        korr    = Npc.create!(name: "Korr",    subrole: "stranger", location: tavern)
        snapshot = Harness::Scene::Assembler.for(location: tavern)
        context.active_scene = Harness::Scene::Active.new(
          location: tavern, snapshot: snapshot, narrations: [],
          internal_state: {},
          agendas:        { maren.id => "wants to ask the player about the docks; her brother went missing last week" },
          extras: []
        )
        result = described_class.new.call({}, context)
        korr_entry = result["present_characters"].find { |c| c["id"] == korr.id }
        expect(korr_entry).not_to have_key("agenda")
      end

      it "omits the agenda key entirely when no NPC has an agenda this scene" do
        Npc.create!(name: "Maren", subrole: "barkeep", location: tavern)
        snapshot = Harness::Scene::Assembler.for(location: tavern)
        context.active_scene = Harness::Scene::Active.new(
          location: tavern, snapshot: snapshot, narrations: [],
          internal_state: {}, agendas: {}, extras: []
        )
        result = described_class.new.call({}, context)
        expect(result["present_characters"].first).not_to have_key("agenda")
      end
    end

    describe "present_extras (ambient nameless figures)" do
      it "exposes extras from the active scene's transient list" do
        maren = Npc.create!(name: "Maren", subrole: "barkeep", location: tavern)
        snapshot = Harness::Scene::Assembler.for(location: tavern)
        context.active_scene = Harness::Scene::Active.new(
          location: tavern, snapshot: snapshot, narrations: [],
          internal_state: { maren.id => "..." },
          extras: [ "an old fisherman nursing a beer at the corner table", "a courier woman finishing a meal" ]
        )
        result = described_class.new.call({}, context)
        expect(result["present_extras"]).to eq([
          "an old fisherman nursing a beer at the corner table",
          "a courier woman finishing a meal"
        ])
      end

      it "returns [] when no active scene is set" do
        Npc.create!(name: "Maren", subrole: "barkeep", location: tavern)
        result = described_class.new.call({}, context)
        expect(result["present_extras"]).to eq([])
      end

      it "returns [] when active scene has no extras" do
        snapshot = Harness::Scene::Assembler.for(location: tavern)
        context.active_scene = Harness::Scene::Active.new(
          location: tavern, snapshot: snapshot, narrations: [],
          internal_state: {}, extras: []
        )
        result = described_class.new.call({}, context)
        expect(result["present_extras"]).to eq([])
      end
    end

    describe "children (regression: previously omitted, hiding sublocations from the LLM)" do
      it "exposes sublocations directly INSIDE the current location as transition targets" do
        tavern  # ensure the let is materialized
        Location.create!(name: "Brewery",  parent: city, description: "smell of grain")
        Location.create!(name: "Smithy",   parent: city, description: "ringing iron")
        city_context = Harness::Turn::Context.new(player_location: city)
        result = described_class.new.call({}, city_context)
        names = result["children"].map { |c| c["name"] }
        expect(names).to contain_exactly("Tavern", "Brewery", "Smithy")
        expect(result["children"].first).to have_key("description")
      end

      it "is empty when the current location has no children" do
        result = described_class.new.call({}, context)  # at tavern, no children
        expect(result["children"]).to eq([])
      end
    end
  end

  describe Harness::Tools::QueryCharacter do
    it "returns the character if found" do
      maren = Npc.create!(name: "Maren", subrole: "barkeep", location: tavern, properties: { "mood" => "wary" })
      result = described_class.new.call({ "character_id" => maren.id }, context)
      expect(result).to include("id" => maren.id, "name" => "Maren", "subrole" => "barkeep", "type" => "Npc")
      expect(result["properties"]).to include("mood" => "wary")
      expect(result).to have_key("abilities")  # nil until materialized
    end

    it "returns the character's abilities when populated" do
      wizard = Npc.create!(
        name: "Arwen", subrole: "wizard", location: tavern,
        abilities: [ { "name" => "Fireball", "stat" => "intelligence" } ]
      )
      result = described_class.new.call({ "character_id" => wizard.id }, context)
      expect(result["abilities"].first["name"]).to eq("Fireball")
    end

    it "finds Player rows too (regression: STI scope used to exclude them)" do
      player = Player.create!(name: "Hero", subrole: "adventurer", location: tavern,
                              properties: { "stamina" => "fresh" })
      result = described_class.new.call({ "character_id" => player.id }, context)
      expect(result).to include("id" => player.id, "name" => "Hero", "type" => "Player")
      expect(result["properties"]).to include("stamina" => "fresh")
    end

    it "returns {error:} for an unknown id instead of raising" do
      result = described_class.new.call({ "character_id" => 99_999 }, context)
      expect(result).to include("error")
    end
  end

  describe Harness::Tools::QueryEvents do
    let(:maren) { Npc.create!(name: "Maren", subrole: "barkeep", location: tavern) }

    it "returns all events when no filters" do
      ev = Event.create!(game_time: 100, scope: "local", location: tavern, details: { "x" => 1 })
      EventParticipant.create!(event: ev, character: maren, role: "actor")

      result = described_class.new.call({}, context)
      expect(result["events"].size).to eq(1)
      expect(result["events"].first["id"]).to eq(ev.id)
      expect(result["events"].first["participants"].first).to include("character_id" => maren.id, "role" => "actor")
    end

    it "filters by character_id via EventParticipant join" do
      stranger = Npc.create!(name: "Stranger", location: tavern)
      ev1 = Event.create!(game_time: 100, scope: "local", location: tavern, details: {})
      ev2 = Event.create!(game_time: 110, scope: "local", location: tavern, details: {})
      EventParticipant.create!(event: ev1, character: maren, role: "actor")
      EventParticipant.create!(event: ev2, character: stranger, role: "actor")

      result = described_class.new.call({ "character_id" => maren.id }, context)
      expect(result["events"].map { |e| e["id"] }).to eq([ ev1.id ])
    end

    it "filters by game_time range" do
      Event.create!(game_time: 50,  scope: "local", location: tavern, details: {})
      mid = Event.create!(game_time: 100, scope: "local", location: tavern, details: {})
      Event.create!(game_time: 150, scope: "local", location: tavern, details: {})

      result = described_class.new.call({ "min_game_time" => 75, "max_game_time" => 125 }, context)
      expect(result["events"].map { |e| e["id"] }).to eq([ mid.id ])
    end

    it "filters by scope" do
      local    = Event.create!(game_time: 100, scope: "local",    location: tavern, details: {})
      regional = Event.create!(game_time: 100, scope: "regional", location: tavern, details: {})

      result = described_class.new.call({ "scope" => "regional" }, context)
      expect(result["events"].map { |e| e["id"] }).to eq([ regional.id ])
    end

    it "orders newest-first by game_time" do
      old    = Event.create!(game_time: 100, scope: "local", location: tavern, details: {})
      newer  = Event.create!(game_time: 200, scope: "local", location: tavern, details: {})

      result = described_class.new.call({}, context)
      expect(result["events"].map { |e| e["id"] }).to eq([ newer.id, old.id ])
    end

    it "respects limit, clamped to MAX_LIMIT" do
      30.times { |i| Event.create!(game_time: i, scope: "local", location: tavern, details: {}) }

      result = described_class.new.call({ "limit" => 5 }, context)
      expect(result["events"].size).to eq(5)

      result = described_class.new.call({ "limit" => 9999 }, context)
      expect(result["events"].size).to eq(described_class::MAX_LIMIT.clamp(1, 30))
    end
  end

  describe Harness::Tools::QueryFaction do
    it "returns the faction" do
      f = Faction.create!(name: "Shadow Hand", subrole: "thieves_guild", is_kingdom: false, properties: { "disposition" => "cagey" })
      result = described_class.new.call({ "faction_id" => f.id }, context)
      expect(result).to include("id" => f.id, "name" => "Shadow Hand", "subrole" => "thieves_guild", "is_kingdom" => false)
      expect(result["properties"]).to include("disposition" => "cagey")
    end

    it "returns {error:} for unknown id" do
      result = described_class.new.call({ "faction_id" => 99_999 }, context)
      expect(result["error"]).to match(/no faction/)
    end

    it "returns {error:} when id missing" do
      result = described_class.new.call({}, context)
      expect(result["error"]).to match(/faction_id required/)
    end
  end

  describe Harness::Tools::QueryItem do
    let(:maren) { Npc.create!(name: "Maren", subrole: "barkeep", location: tavern) }

    it "returns an anchored item" do
      mug = Item.create!(name: "Mug", subrole: "drinkware", location: tavern)
      result = described_class.new.call({ "item_id" => mug.id }, context)
      expect(result).to include("id" => mug.id, "name" => "Mug", "location_id" => tavern.id, "character_id" => nil)
    end

    it "returns an owned item" do
      ledger = Item.create!(name: "Ledger", subrole: "document", character: maren)
      result = described_class.new.call({ "item_id" => ledger.id }, context)
      expect(result).to include("id" => ledger.id, "character_id" => maren.id, "location_id" => nil)
    end

    it "returns {error:} for unknown id" do
      result = described_class.new.call({ "item_id" => 99_999 }, context)
      expect(result["error"]).to match(/no item/)
    end
  end

  describe Harness::Tools::Transition do
    it "moves the player to a sibling location and marks scene_dirty" do
      warehouse = Location.create!(name: "Warehouse", parent: city)
      result = described_class.new.call({ "destination_id" => warehouse.id }, context)
      expect(result["moved_to"]).to include("name" => "Warehouse")
      expect(context.player_location).to eq(warehouse)
      expect(context.scene_dirty).to be(true)
    end

    it "advances game_time by MOVE_COST for sibling moves" do
      warehouse = Location.create!(name: "Warehouse", parent: city)
      expect {
        described_class.new.call({ "destination_id" => warehouse.id }, context)
      }.to change { context.game_time }.by(Harness::Tools::Transition::MOVE_COST)
    end

    # Path-edge traversal was retired with the Path model. Inter-city
    # movement is the `travel` tool's job; transition is intra-city only.

    it "refuses unreachable destinations and does not advance game_time" do
      island = Location.create!(name: "Island")
      expect {
        result = described_class.new.call({ "destination_id" => island.id }, context)
        expect(result["error"]).to match(/not reachable/)
      }.not_to change { context.game_time }
      expect(context.player_location).to eq(tavern)
    end

    describe "player.location persistence (regression)" do
      it "updates Player.location_id in the DB so a session restart finds the player at the new location" do
        warehouse = Location.create!(name: "Warehouse", parent: city)
        player = Player.create!(name: "Hero", location: tavern)
        described_class.new.call({ "destination_id" => warehouse.id }, context)
        expect(player.reload.location_id).to eq(warehouse.id)
      end

      it "is a no-op on Player when no Player row exists (test/worldgen contexts)" do
        warehouse = Location.create!(name: "Warehouse", parent: city)
        expect(Player.count).to eq(0)
        expect {
          described_class.new.call({ "destination_id" => warehouse.id }, context)
        }.not_to raise_error
      end
    end
  end
end
