require "rails_helper"

RSpec.describe "Harness::Tools propose family" do
  let(:city)    { Location.create!(name: "Saltmere") }
  let(:tavern)  { Location.create!(name: "Tavern", parent: city) }
  let(:warehouse) { Location.create!(name: "Warehouse", parent: city) }
  let(:maren) { Npc.create!(name: "Maren", subrole: "barkeep", location: tavern) }
  let(:context) { Harness::Turn::Context.new(player_location: tavern, game_time: 100) }

  describe Harness::Tools::ProposeEvent do
    it "appends a forward event with participants and advances game_time" do
      expect {
        result = described_class.new.call(
          {
            "scope"        => "local",
            "trigger"      => "tavern brawl",
            "details"      => "Two patrons came to blows over a spilled drink.",
            "participants" => [ { "character_id" => maren.id, "role" => "witness" } ]
          },
          context
        )
        expect(result["event_id"]).to be_present
        expect(result["scope"]).to eq("local")
        expect(result["game_time"]).to eq(101)
        expect(result["participants"].first).to include("character_id" => maren.id, "role" => "witness")
      }.to change(Event, :count).by(1)

      ev = Event.last
      expect(ev.scope).to eq("local")
      expect(ev.game_time).to eq(101)
      expect(ev.location).to eq(tavern)
      expect(ev.details["narrative"]).to include("trigger" => "tavern brawl")
      expect(ev.event_participants.first.character).to eq(maren)
      expect(ev.event_participants.first.role).to eq("witness")
      expect(context.game_time).to eq(101)
    end

    it "defaults location to player_location" do
      described_class.new.call(
        { "scope" => "personal", "trigger" => "an arrival" },
        context
      )
      expect(Event.last.location).to eq(tavern)
    end

    it "accepts an explicit location_id override" do
      described_class.new.call(
        { "scope" => "personal", "trigger" => "an arrival", "location_id" => warehouse.id },
        context
      )
      expect(Event.last.location).to eq(warehouse)
    end

    it "allows zero participants" do
      expect {
        described_class.new.call(
          { "scope" => "regional", "trigger" => "the alarm bell rings" },
          context
        )
      }.to change(Event, :count).by(1)
      expect(Event.last.event_participants).to be_empty
    end

    it "rejects invalid scope" do
      result = described_class.new.call(
        { "scope" => "cosmic", "trigger" => "foo" },
        context
      )
      expect(result["error"]).to match(/scope must be one of/)
    end

    it "rejects empty trigger" do
      result = described_class.new.call(
        { "scope" => "personal", "trigger" => "  " },
        context
      )
      expect(result["error"]).to match(/trigger must be/)
    end

    it "rejects unknown character_id in participants" do
      result = described_class.new.call(
        {
          "scope"        => "personal",
          "trigger"      => "x",
          "participants" => [ { "character_id" => 99_999, "role" => "actor" } ]
        },
        context
      )
      expect(result["error"]).to match(/no character with id=99999/)
    end

    it "rejects participant missing role" do
      result = described_class.new.call(
        {
          "scope"        => "personal",
          "trigger"      => "x",
          "participants" => [ { "character_id" => maren.id } ]
        },
        context
      )
      expect(result["error"]).to match(/role must be/)
    end

    describe "post-Phase-2: class-2 actor_name retired" do
      it "rejects participants with actor_name strings, pointing to propose_character" do
        result = described_class.new.call(
          {
            "scope"        => "local",
            "trigger"      => "the tavern was built",
            "details"      => "A retired shipwright raised the place forty-five years ago.",
            "participants" => [ { "actor_name" => "Old Marn", "role" => "builder" } ]
          },
          context
        )
        expect(result["error"]).to match(/actor_name is no longer supported/)
        expect(result["error"]).to match(/propose_character/)
      end

      it "rejects a participant missing character_id" do
        result = described_class.new.call(
          {
            "scope"        => "personal",
            "trigger"      => "x",
            "participants" => [ { "role" => "witness" } ]
          },
          context
        )
        expect(result["error"]).to match(/character_id must be an integer/)
      end
    end

    it "rejects unknown location_id" do
      result = described_class.new.call(
        { "scope" => "personal", "trigger" => "x", "location_id" => 99_999 },
        context
      )
      expect(result["error"]).to match(/no location with id=99999/)
    end

    it "does not create an event when validation fails" do
      expect {
        described_class.new.call({ "scope" => "weird", "trigger" => "x" }, context)
      }.not_to change(Event, :count)
    end

    describe "backward mode (game_time < current)" do
      let(:llm_consistent) { StubLLM.new { |_p| { "consistent" => true, "reasons" => [] }.to_json } }

      it "dispatches to the backward-append pipe and reports mode: backward" do
        context.llm_client = llm_consistent
        # current game_time is 100; propose at 50
        result = nil
        expect {
          result = described_class.new.call(
            {
              "scope"     => "personal",
              "trigger"   => "an old quarrel",
              "details"   => "Maren and Korr had words about a debt",
              "game_time" => 50,
              "participants" => [
                { "character_id" => maren.id, "role" => "actor" }
              ]
            },
            context
          )
        }.to change(Event, :count).by(1)
        expect(result["mode"]).to eq("backward")
        expect(result["game_time"]).to eq(50)
        # backward mode does NOT advance the clock
        expect(context.game_time).to eq(100)
      end

      it "stays in forward mode when game_time is omitted" do
        result = described_class.new.call(
          { "scope" => "personal", "trigger" => "now" },
          context
        )
        expect(result["mode"]).to eq("forward")
      end

      it "stays in forward mode when game_time equals current (not strictly less)" do
        result = described_class.new.call(
          { "scope" => "personal", "trigger" => "now", "game_time" => 100 },
          context
        )
        expect(result["mode"]).to eq("forward")
      end

      it "returns {error:, kind: 'contradiction'} when the validator rejects" do
        # Seed an after-event so pre-filter has something for the validator to judge.
        Event.create!(game_time: 80, scope: "personal", location: tavern, details: {})

        context.llm_client = StubLLM.new { |_p|
          {
            "consistent" => false,
            "reasons"    => [ "this contradicts" ]
          }.to_json
        }

        result = described_class.new.call(
          {
            "scope"     => "personal",
            "trigger"   => "old death",
            "details"   => "X dies",
            "game_time" => 50,
            "participants" => [ { "character_id" => maren.id, "role" => "actor" } ]
          },
          context
        )
        expect(result["error"]).to match(/rejected/)
        expect(result["kind"]).to eq("contradiction")
        expect(result["reasons"]).to eq([ "this contradicts" ])
      end

      it "returns {error:, kind: 'floor_violation'} when proposed game_time is below participant floor" do
        # Seed an event with Maren at game_time=80 → his floor is 80
        ev = Event.create!(game_time: 80, scope: "personal", location: tavern, details: {})
        EventParticipant.create!(event: ev, character: maren, role: "actor")

        context.llm_client = llm_consistent

        result = described_class.new.call(
          {
            "scope"     => "personal",
            "trigger"   => "way too old",
            "game_time" => 50,
            "participants" => [ { "character_id" => maren.id, "role" => "actor" } ]
          },
          context
        )
        expect(result["error"]).to match(/below participant Maren/)
        expect(result["kind"]).to eq("floor_violation")
      end
    end

  end

  describe Harness::Tools::ProposeCharacter do
    it "creates an Npc at the current location without advancing game_time" do
      expect {
        result = described_class.new.call(
          {
            "name"       => "Korr",
            "subrole"    => "stranger",
            "connection" => "newcomer drawn by the rumor of the missing courier"
          },
          context
        )
        expect(result["character_id"]).to be_present
        expect(result["name"]).to eq("Korr")
        expect(result["location_id"]).to eq(tavern.id)
        expect(result["game_time"]).to eq(100)
      }.to change(Npc, :count).by(1)
      expect(context.game_time).to eq(100)

      korr = Npc.last
      expect(korr.location).to eq(tavern)
      expect(korr.subrole).to eq("stranger")
    end

    it "homes a character spawned in a settlement (home == spawn location)" do
      described_class.new.call(
        { "name" => "Bess", "subrole" => "weaver", "connection" => "lives in town" }, context
      )
      expect(Npc.find_by(name: "Bess").home_location_id).to eq(tavern.id)
    end

    it "leaves a character spawned at a social waypoint homeless (a passing traveler)" do
      waypoint = Location.create!(name: "Crossing", x: 5.0, y: 5.0, biome: "lowland",
                                  properties: { "kind" => "wilderness_leaf", "encounter_type" => "social" })
      ctx = Harness::Turn::Context.new(player_location: waypoint, game_time: 100)
      described_class.new.call(
        { "name" => "Hodge", "subrole" => "traveler", "connection" => "passing through" }, ctx
      )
      expect(Npc.find_by(name: "Hodge").home_location_id).to be_nil
    end

    it "homes a character spawned at a lair to the lair (a bandit lives at his ambush site)" do
      lair = Location.create!(name: "Ambush Bend", x: 6.0, y: 6.0, biome: "lowland",
                              properties: { "kind" => "wilderness_leaf", "encounter_type" => "combat" })
      ctx = Harness::Turn::Context.new(player_location: lair, game_time: 100)
      described_class.new.call(
        { "name" => "Vorn", "subrole" => "bandit", "connection" => "ambushes the pass" }, ctx
      )
      expect(Npc.find_by(name: "Vorn").home_location_id).to eq(lair.id)
    end

    it "stores initial properties" do
      described_class.new.call(
        {
          "name"       => "Jeni",
          "subrole"    => "courier",
          "connection" => "sent from upriver",
          "properties" => { "mood" => "anxious", "faction_id" => 42 }
        },
        context
      )
      expect(Npc.last.properties).to include("mood" => "anxious", "faction_id" => 42)
    end

    it "accepts a location_id override" do
      described_class.new.call(
        {
          "name" => "Korr", "subrole" => "stranger", "connection" => "x",
          "location_id" => warehouse.id
        },
        context
      )
      expect(Npc.last.location).to eq(warehouse)
    end

    it "logs an introduction event with the new npc as subject" do
      described_class.new.call(
        { "name" => "Korr", "subrole" => "stranger", "connection" => "rumor" },
        context
      )
      ev = Event.last
      expect(ev.scope).to eq("personal")
      expect(ev.location).to eq(tavern)
      expect(ev.details["introduction"]).to include(
        "target_type" => "character",
        "target_name" => "Korr",
        "subrole"     => "stranger",
        "connection"  => "rumor"
      )
      expect(ev.event_participants.first.character).to eq(Npc.last)
      expect(ev.event_participants.first.role).to eq("subject")
    end

    it "the introduction event also carries a narrative payload so the new NPC's connection prose surfaces via query_events" do
      # Regression: pre-fix, propose_character buried the `connection` prose
      # in details.introduction.connection. query_events filtered introductions
      # out of the narrative scope, so a freshly-spawned NPC like
      # "Jemima Voss, a younger merchant whose shipment of grain went missing"
      # had nothing in her structural recall about why she existed. The fix
      # adds a `narrative` payload alongside `introduction` so query_events'
      # `queryable` scope surfaces the connection prose as the NPC's reason
      # for existing.
      described_class.new.call(
        { "name" => "Jemima", "subrole" => "merchant",
          "connection" => "a younger caravan master whose grain shipment vanished near Marrow's End" },
        context
      )
      jemima = Npc.find_by!(name: "Jemima")

      result = Harness::Tools::QueryEvents.new.call({ "for_holder_id" => jemima.id }, context)
      details = result["events"].map { |e| e["details"] }
      narrative = details.find { |d| d["narrative"].is_a?(Hash) && d.dig("narrative", "details").to_s.include?("grain shipment vanished") }
      expect(narrative).to be_present, "connection prose should surface in for_holder_id query as a narrative payload (got: #{result['events'].inspect})"
      expect(narrative.dig("narrative", "trigger")).to match(/introduced/)
    end

    it "rejects empty name" do
      result = described_class.new.call(
        { "name" => "  ", "subrole" => "x", "connection" => "y" },
        context
      )
      expect(result["error"]).to match(/name must be/)
    end

    it "rejects empty subrole" do
      result = described_class.new.call(
        { "name" => "Korr", "subrole" => "", "connection" => "y" },
        context
      )
      expect(result["error"]).to match(/subrole must be/)
    end

    it "rejects empty connection (no orphan content)" do
      result = described_class.new.call(
        { "name" => "Korr", "subrole" => "stranger", "connection" => " " },
        context
      )
      expect(result["error"]).to match(/connection must be/)
    end

    it "rejects unknown location_id" do
      result = described_class.new.call(
        {
          "name" => "Korr", "subrole" => "stranger", "connection" => "x",
          "location_id" => 99_999
        },
        context
      )
      expect(result["error"]).to match(/no location with id=99999/)
    end

    it "does not create an Npc or event on validation failure" do
      expect {
        described_class.new.call(
          { "name" => "", "subrole" => "x", "connection" => "y" },
          context
        )
      }.to change(Npc, :count).by(0).and change(Event, :count).by(0)
    end

    describe "from_extra (promoting an ambient figure)" do
      let(:extras) {
        [
          "a dockworker in the corner, hat pulled low, working through a plate of bread and pickled fish",
          "a woman at the bar nursing a drink and staring into the fireplace's dying coals"
        ]
      }
      let(:active) {
        Harness::Scene::Active.new(
          location: tavern, snapshot: nil, narrations: [],
          internal_state: {}, agendas: {}, extras: extras,
          entered_at_game_time: 0
        )
      }

      before { context.active_scene = active }

      it "removes the matching extra from active.extras when an exact string matches" do
        described_class.new.call(
          {
            "name"       => "Marek",
            "subrole"    => "dockworker",
            "connection" => "the dockworker who'd been eating in the corner",
            "from_extra" => extras.first
          },
          context
        )
        expect(active.present_extras).to eq([ extras.last ])
      end

      it "still creates the Npc and introduction event when from_extra is matched" do
        expect {
          described_class.new.call(
            {
              "name" => "Marek", "subrole" => "dockworker",
              "connection" => "promoted from corner extra",
              "from_extra" => extras.first
            },
            context
          )
        }.to change(Npc, :count).by(1).and change(Event, :count).by(1)
      end

      it "rejects when no extra matches the string (no Npc created)" do
        expect {
          result = described_class.new.call(
            {
              "name" => "Marek", "subrole" => "dockworker", "connection" => "x",
              "from_extra" => "a description that isn't in the extras list"
            },
            context
          )
          expect(result["error"]).to match(/no extra matches/)
        }.to change(Npc, :count).by(0).and change(Event, :count).by(0)
        expect(active.present_extras).to eq(extras)  # unchanged
      end

      it "rejects when there is no active scene" do
        context.active_scene = nil
        result = described_class.new.call(
          {
            "name" => "Marek", "subrole" => "dockworker", "connection" => "x",
            "from_extra" => extras.first
          },
          context
        )
        expect(result["error"]).to match(/no active scene/)
      end

      it "is optional — calling without from_extra works as before" do
        expect {
          described_class.new.call(
            { "name" => "Marek", "subrole" => "dockworker", "connection" => "x" },
            context
          )
        }.to change(Npc, :count).by(1)
        expect(active.present_extras).to eq(extras)  # untouched
      end
    end

    describe "name collision detection" do
      it "rejects an exact-name collision against an existing character at the same city ancestry" do
        existing = Npc.create!(name: "Marta", subrole: "shepherd", location: city)
        result = described_class.new.call(
          { "name" => "Marta", "subrole" => "innkeeper", "connection" => "runs the inn" },
          context  # context.player_location is tavern, child of city
        )
        expect(result["error"]).to match(/name collision/)
        expect(result["existing_character"]).to include("character_id" => existing.id, "name" => "Marta")
      end

      it "rejects a first-token collision (the Marta-of-the-Moss case)" do
        # Genesis-style: Marta of the Moss exists at the parent city
        existing = Npc.create!(name: "Marta of the Moss", location: city)
        result = described_class.new.call(
          { "name" => "Marta", "subrole" => "innkeeper", "connection" => "runs the inn" },
          context
        )
        expect(result["error"]).to match(/name collision/)
        expect(result["existing_character"]).to include("character_id" => existing.id, "name" => "Marta of the Moss")
      end

      it "rejects the reverse-direction first-token collision too (proposed full name vs existing short)" do
        existing = Npc.create!(name: "Marta", location: city)
        result = described_class.new.call(
          { "name" => "Marta of the Moss", "subrole" => "discoverer", "connection" => "moss expert" },
          context
        )
        expect(result["error"]).to match(/name collision/)
        expect(result["existing_character"]).to include("character_id" => existing.id)
      end

      it "is case-insensitive" do
        Npc.create!(name: "Marta", location: city)
        result = described_class.new.call(
          { "name" => "MARTA", "subrole" => "innkeeper", "connection" => "x" },
          context
        )
        expect(result["error"]).to match(/name collision/)
      end

      it "creates without collision when no namesake exists" do
        Npc.create!(name: "Aldric the Scout", location: city)
        expect {
          result = described_class.new.call(
            { "name" => "Marta", "subrole" => "innkeeper", "connection" => "x" },
            context
          )
          expect(result["character_id"]).to be_present
        }.to change(Npc, :count).by(1)
      end

      it "does not flag distinct first-tokens that happen to share a substring (John vs Johnson)" do
        Npc.create!(name: "Johnson", location: city)
        expect {
          result = described_class.new.call(
            { "name" => "John", "subrole" => "blacksmith", "connection" => "x" },
            context
          )
          expect(result["character_id"]).to be_present
        }.to change(Npc, :count).by(1)
      end

      it "checks ancestry — collision in a sibling sublocation also flags" do
        existing = Npc.create!(name: "Korr", location: warehouse)
        result = described_class.new.call(
          { "name" => "Korr", "subrole" => "patron", "connection" => "x" },
          context
        )
        expect(result["error"]).to match(/name collision/)
        expect(result["existing_character"]).to include("character_id" => existing.id)
      end

      it "does NOT flag against characters at unrelated cities" do
        other_city = Location.create!(name: "Ironwood")
        Npc.create!(name: "Marta", location: other_city)
        expect {
          result = described_class.new.call(
            { "name" => "Marta", "subrole" => "innkeeper", "connection" => "x" },
            context
          )
          expect(result["character_id"]).to be_present
        }.to change(Npc, :count).by(1)
      end
    end
  end

  describe Harness::Tools::ProposeFaction do
    it "creates a non-kingdom faction by default without advancing game_time" do
      expect {
        result = described_class.new.call(
          {
            "name"       => "Shadow Hand",
            "subrole"    => "thieves_guild",
            "connection" => "patron muttered the name during a fight"
          },
          context
        )
        expect(result["faction_id"]).to be_present
        expect(result["is_kingdom"]).to be(false)
        expect(result["game_time"]).to eq(100)
      }.to change(Faction, :count).by(1)
      expect(context.game_time).to eq(100)
      expect(Faction.last.is_kingdom).to be(false)
    end

    it "creates a kingdom faction" do
      described_class.new.call(
        {
          "name" => "Meathead Realm", "subrole" => "kingdom",
          "is_kingdom" => true, "connection" => "courier wore their seal"
        },
        context
      )
      expect(Faction.last.is_kingdom).to be(true)
    end

    it "stores properties" do
      described_class.new.call(
        {
          "name" => "Shadow Hand", "subrole" => "thieves_guild", "connection" => "x",
          "properties" => { "disposition" => "cagey", "reach" => "citywide" }
        },
        context
      )
      expect(Faction.last.properties).to include("disposition" => "cagey", "reach" => "citywide")
    end

    it "logs a local-scope introduction event with no participants" do
      described_class.new.call(
        { "name" => "Shadow Hand", "subrole" => "thieves_guild", "connection" => "rumor" },
        context
      )
      ev = Event.last
      expect(ev.scope).to eq("local")
      expect(ev.location).to eq(tavern)
      expect(ev.event_participants).to be_empty
      expect(ev.details["introduction"]).to include(
        "target_type" => "faction",
        "target_name" => "Shadow Hand",
        "is_kingdom"  => false,
        "connection"  => "rumor"
      )
    end

    it "rejects non-boolean is_kingdom" do
      result = described_class.new.call(
        {
          "name" => "X", "subrole" => "y", "connection" => "z",
          "is_kingdom" => "yes"
        },
        context
      )
      expect(result["error"]).to match(/is_kingdom must be boolean/)
    end

    it "rejects empty connection" do
      result = described_class.new.call(
        { "name" => "X", "subrole" => "y", "connection" => "" },
        context
      )
      expect(result["error"]).to match(/connection must be/)
    end
  end

  describe Harness::Tools::ProposeItem do
    it "creates an item anchored to a location" do
      expect {
        result = described_class.new.call(
          {
            "name"        => "Sealed Letter",
            "subrole"     => "document",
            "connection"  => "left for Maren by the morning courier",
            "location_id" => tavern.id
          },
          context
        )
        expect(result["item_id"]).to be_present
        expect(result["location_id"]).to eq(tavern.id)
        expect(result["character_id"]).to be_nil
      }.to change(Item, :count).by(1)
      expect(Item.last.location).to eq(tavern)
    end

    it "creates an item owned by a character" do
      result = described_class.new.call(
        {
          "name" => "Brass Key", "subrole" => "tool", "connection" => "Korr's keepsake",
          "character_id" => maren.id
        },
        context
      )
      expect(result["character_id"]).to eq(maren.id)
      expect(result["location_id"]).to be_nil
      expect(Item.last.character).to eq(maren)
    end

    it "logs an introduction event at holder's location with holder as participant when owned" do
      described_class.new.call(
        {
          "name" => "Brass Key", "subrole" => "tool", "connection" => "x",
          "character_id" => maren.id
        },
        context
      )
      ev = Event.last
      expect(ev.location).to eq(tavern)
      expect(ev.event_participants.first.character).to eq(maren)
      expect(ev.event_participants.first.role).to eq("holder")
      expect(ev.details["introduction"]).to include("target_type" => "item", "owned_by" => maren.id)
    end

    it "logs an introduction event at the anchor location with no participants when anchored" do
      described_class.new.call(
        {
          "name" => "Sealed Letter", "subrole" => "document", "connection" => "x",
          "location_id" => warehouse.id
        },
        context
      )
      ev = Event.last
      expect(ev.location).to eq(warehouse)
      expect(ev.event_participants).to be_empty
      expect(ev.details["introduction"]).to include("anchored_at" => warehouse.id, "owned_by" => nil)
    end

    it "rejects neither location_id nor character_id" do
      result = described_class.new.call(
        { "name" => "X", "subrole" => "y", "connection" => "z" },
        context
      )
      expect(result["error"]).to match(/exactly one of location_id or character_id required/)
    end

    it "rejects both location_id and character_id" do
      result = described_class.new.call(
        {
          "name" => "X", "subrole" => "y", "connection" => "z",
          "location_id" => tavern.id, "character_id" => maren.id
        },
        context
      )
      expect(result["error"]).to match(/exactly one of location_id or character_id allowed/)
    end

    it "rejects unknown character_id" do
      result = described_class.new.call(
        {
          "name" => "X", "subrole" => "y", "connection" => "z",
          "character_id" => 99_999
        },
        context
      )
      expect(result["error"]).to match(/no character with id=99999/)
    end

    it "rejects unknown location_id" do
      result = described_class.new.call(
        {
          "name" => "X", "subrole" => "y", "connection" => "z",
          "location_id" => 99_999
        },
        context
      )
      expect(result["error"]).to match(/no location with id=99999/)
    end

    it "rejects empty connection" do
      result = described_class.new.call(
        {
          "name" => "X", "subrole" => "y", "connection" => "",
          "location_id" => tavern.id
        },
        context
      )
      expect(result["error"]).to match(/connection must be/)
    end
  end

  describe "registered in Resolver::DEFAULT_TOOLS" do
    it "exposes all four propose tools" do
      names = Harness::Resolver::DEFAULT_TOOLS.map(&:tool_name)
      expect(names).to include("propose_event", "propose_character", "propose_faction", "propose_item")
    end
  end
end
