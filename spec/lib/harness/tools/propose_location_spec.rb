require "rails_helper"

RSpec.describe Harness::Tools::ProposeLocation do
  let(:saltmere) { Location.create!(name: "Saltmere", description: "harbor town", x: 10.0, y: 10.0, biome: "lowland") }
  let(:ice_city) { Location.create!(name: "City of Ice", description: "frozen pinnacle", x: 30.0, y: 8.0, biome: "highland") }
  let(:tavern)   { Location.create!(name: "Tavern", parent: saltmere) }
  let(:context)  { Harness::Turn::Context.new(player_location: saltmere, game_time: 100) }

  describe "sublocation" do
    it "creates a Location with parent_id set, no x/y/biome" do
      saltmere
      result = described_class.new.call(
        {
          "name"        => "Old Customs House",
          "description" => "a worn brick building near the docks",
          "type"        => "sublocation",
          "parent_id"   => saltmere.id,
          "connection"  => "the customs office Korr mentioned"
        },
        context
      )
      loc = ::Location.find(result["location_id"])
      expect(loc.name).to eq("Old Customs House")
      expect(loc.parent_id).to eq(saltmere.id)
      expect(loc.x).to be_nil
      expect(loc.biome).to be_nil
    end

    it "logs an introduction event without advancing game_time" do
      saltmere
      expect {
        described_class.new.call(
          {
            "name" => "Old Customs House", "description" => "a worn brick building",
            "type" => "sublocation", "parent_id" => saltmere.id, "connection" => "x"
          },
          context
        )
      }.to change(Event, :count).by(1)
      expect(context.game_time).to eq(100)
      ev = Event.last
      expect(ev.details["introduction"]).to include(
        "target_type" => "location",
        "kind"        => "sublocation",
        "connection"  => "x"
      )
    end

    it "rejects when parent_id is missing" do
      result = described_class.new.call(
        { "name" => "X", "description" => "y", "type" => "sublocation", "connection" => "z" },
        context
      )
      expect(result["error"]).to match(/parent_id is required/)
    end

    it "rejects when parent_id refers to no row" do
      result = described_class.new.call(
        { "name" => "X", "description" => "y", "type" => "sublocation", "parent_id" => 99999, "connection" => "z" },
        context
      )
      expect(result["error"]).to match(/no location with id=99999/)
    end
  end

  describe "wilderness_leaf" do
    it "creates a top-level Location with sampled coords + biome inherited from nearest" do
      saltmere; ice_city
      result = described_class.new.call(
        {
          "name"        => "Hollowmere",
          "description" => "a misty hollow village",
          "type"        => "wilderness_leaf",
          "connection"  => "a wayshrine across the river from Saltmere"
        },
        context
      )
      loc = ::Location.find(result["location_id"])
      expect(loc.parent_id).to be_nil
      expect(loc.x).to be_a(Float)
      expect(loc.y).to be_a(Float)
      expect(::Harness::Worldgen::Biome::ALL).to include(loc.biome)
    end

    it "tags the new location with properties.kind=\"wilderness_leaf\" so the auto-Materializer at scene entry knows to spawn NPCs" do
      saltmere; ice_city
      described_class.new.call(
        { "name" => "Hollowmere", "description" => "x", "type" => "wilderness_leaf", "connection" => "y" },
        context
      )
      loc = ::Location.find_by(name: "Hollowmere")
      expect(loc.properties["kind"]).to eq("wilderness_leaf")
    end

    it "errors when the player is not anchored at a top-level coordinated location" do
      orphan = Location.create!(name: "Orphan", description: "no coords")
      ctx = Harness::Turn::Context.new(player_location: orphan, game_time: 100)
      result = described_class.new.call(
        { "name" => "Hollowmere", "description" => "x", "type" => "wilderness_leaf", "connection" => "y" },
        ctx
      )
      expect(result["error"]).to match(/cannot place a wilderness_leaf/)
    end

    it "logs a local-scope introduction event" do
      saltmere
      described_class.new.call(
        { "name" => "Hollowmere", "description" => "x", "type" => "wilderness_leaf", "connection" => "y" },
        context
      )
      ev = Event.last
      expect(ev.scope).to eq("local")
      expect(ev.details["introduction"]["kind"]).to eq("wilderness_leaf")
    end
  end

  describe "prose backfill" do
    it "rewrites prior events that referenced the new name in details.location_name" do
      saltmere
      Harness::Event::ForwardAppender.append(
        game_time: 50, scope: "regional", location: "Hollowmere",
        details: { "summary" => "early mention" }
      )
      Harness::Event::ForwardAppender.append(
        game_time: 51, scope: "regional", location: "Hollowmere"
      )

      result = described_class.new.call(
        { "name" => "Hollowmere", "description" => "x", "type" => "wilderness_leaf", "connection" => "y" },
        context
      )
      expect(result["events_backfilled"]).to eq(2)

      new_loc = ::Location.find(result["location_id"])
      backfilled_events = Event.where(location: new_loc).where("game_time < ?", context.game_time)
      expect(backfilled_events.count).to eq(2)
      backfilled_events.each do |ev|
        expect(ev.details).not_to have_key("location_name")
      end
    end

    it "leaves unrelated events alone" do
      saltmere
      Harness::Event::ForwardAppender.append(
        game_time: 50, scope: "regional", location: "Different Place"
      )
      result = described_class.new.call(
        { "name" => "Hollowmere", "description" => "x", "type" => "wilderness_leaf", "connection" => "y" },
        context
      )
      expect(result["events_backfilled"]).to eq(0)
      other = Event.where(location_id: nil).first
      expect(other.details["location_name"]).to eq("Different Place")
    end
  end

  describe "genesis (intentionally NOT run for wilderness_leafs — MVP)" do
    # Genesis was previously back-generating 0-5 past events per
    # wilderness_leaf creation. Retired: leaves are ephemeral by design
    # (encounters, transient way-stations) and the texture wasn't paying for
    # itself. Worldgen cities still run genesis-on-entry via Scene::Manager;
    # that's where it earns its keep. Reinstate per-leaf genesis only when
    # there's a real product reason.
    let(:would_be_genesis_llm) { StubLLM.new { |_p| raise "genesis must NOT be called for wilderness_leafs" } }

    it "does not call the LLM for genesis on wilderness_leaf" do
      saltmere
      ctx = Harness::Turn::Context.new(player_location: saltmere, game_time: 1000, llm_grunt: would_be_genesis_llm)

      expect {
        result = described_class.new.call(
          { "name" => "Hollowmere", "description" => "x", "type" => "wilderness_leaf", "connection" => "y" },
          ctx
        )
        expect(result.key?("genesis_event_ids")).to be(false)
      }.to change(Event, :count).by(1)  # only the intro event
    end

    it "does not call the LLM for genesis on sublocation either" do
      saltmere
      ctx = Harness::Turn::Context.new(player_location: saltmere, game_time: 1000, llm_grunt: would_be_genesis_llm)

      expect {
        described_class.new.call(
          { "name" => "Old Customs House", "description" => "x", "type" => "sublocation", "parent_id" => saltmere.id, "connection" => "y" },
          ctx
        )
      }.to change(Event, :count).by(1)
    end
  end

  describe "validation" do
    it "rejects bad type" do
      result = described_class.new.call(
        { "name" => "X", "description" => "y", "type" => "city", "connection" => "z" },
        context
      )
      expect(result["error"]).to match(/type must be one of/)
    end

    it "rejects empty name" do
      result = described_class.new.call(
        { "name" => "  ", "description" => "y", "type" => "sublocation", "parent_id" => saltmere.id, "connection" => "z" },
        context
      )
      expect(result["error"]).to match(/name must be/)
    end

    it "rejects duplicate names" do
      saltmere
      result = described_class.new.call(
        { "name" => "Saltmere", "description" => "y", "type" => "wilderness_leaf", "connection" => "z" },
        context
      )
      expect(result["error"]).to match(/already exists/)
    end
  end
end
