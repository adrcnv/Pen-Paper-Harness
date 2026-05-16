require "rails_helper"

RSpec.describe Harness::Tools::QueryLocationByName do
  let(:saltmere) { Location.create!(name: "Saltmere", description: "harbor town", x: 10.0, y: 10.0, biome: "lowland") }
  let(:ice_city) { Location.create!(name: "City of Ice", description: "frozen pinnacle", x: 30.0, y: 8.0, biome: "highland") }
  let(:tavern)   { Location.create!(name: "Tavern", parent: saltmere) }
  let(:context)  { Harness::Turn::Context.new(player_location: tavern, game_time: 100) }

  describe "exact match" do
    it "returns row data when an exact match exists" do
      saltmere
      result = described_class.new.call({ "name" => "Saltmere" }, context)
      expect(result["found"]).to be(true)
      expect(result["location_id"]).to eq(saltmere.id)
      expect(result["x"]).to eq(10.0)
      expect(result["biome"]).to eq("lowland")
    end

    it "returns sublocation row data with parent_id set" do
      tavern
      result = described_class.new.call({ "name" => "Tavern" }, context)
      expect(result["found"]).to be(true)
      expect(result["parent_id"]).to eq(saltmere.id)
      expect(result["x"]).to be_nil
    end
  end

  describe "no match" do
    it "returns mention count when no row exists but events reference the name" do
      saltmere; ice_city
      Harness::Event::ForwardAppender.append(
        game_time: 50, scope: "regional", location: "Plains of Korr"
      )
      Harness::Event::ForwardAppender.append(
        game_time: 51, scope: "regional", location: "Plains of Korr"
      )

      result = described_class.new.call({ "name" => "Plains of Korr" }, context)
      expect(result["found"]).to be(false)
      expect(result["mentioned_in_events"]).to eq(2)
    end

    it "returns zero mentions when the name has never been referenced" do
      saltmere
      result = described_class.new.call({ "name" => "Atlantis" }, context)
      expect(result["mentioned_in_events"]).to eq(0)
    end

    it "returns the full known top-level pool so the reasoning loop can resolve near-misses itself" do
      saltmere; ice_city; tavern  # tavern is a sublocation under saltmere
      result = described_class.new.call({ "name" => "Ice City" }, context)
      # similar_known includes sublocations under the player's anchor (so casual
      # references like "the tavern" can resolve to existing rows) PLUS the
      # top-level pool. Each entry has id + name + parent_id (null for top-level).
      names = result["similar_known"].map { |e| e["name"] }
      expect(names).to contain_exactly("Tavern", "Saltmere", "City of Ice")
    end

    it "surfaces sibling sublocations under the player's anchor (regression: 'go to the brewery' should resolve)" do
      saltmere
      Location.create!(name: "Tiderun Brewery", parent: saltmere)
      Location.create!(name: "Smithy",          parent: saltmere)
      result = described_class.new.call({ "name" => "brewery" }, context)
      expect(result["found"]).to be(false)
      names = result["similar_known"].map { |e| e["name"] }
      expect(names).to include("Tiderun Brewery", "Smithy")
    end

    it "when player is at a top-level city, surfaces its child sublocations" do
      saltmere
      brewery = Location.create!(name: "Brewery", parent: saltmere)
      city_context = Harness::Turn::Context.new(player_location: saltmere, game_time: 100)
      result = described_class.new.call({ "name" => "missing" }, city_context)
      names = result["similar_known"].map { |e| e["name"] }
      expect(names).to include("Brewery")
    end

    it "carries id + name + parent_id on every similar_known entry (so the LLM has the id for travel/transition)" do
      saltmere; ice_city; tavern
      result = described_class.new.call({ "name" => "missing" }, context)
      result["similar_known"].each do |entry|
        expect(entry).to include("id", "name", "parent_id")
        expect(entry["id"]).to be_a(Integer)
      end
      # parent_id distinguishes top-level (travel target) from sublocation
      # (transition target). Saltmere/City of Ice are top-level → parent_id nil;
      # Tavern is a sublocation → parent_id == saltmere.id.
      saltmere_entry = result["similar_known"].find { |e| e["name"] == "Saltmere" }
      tavern_entry   = result["similar_known"].find { |e| e["name"] == "Tavern" }
      expect(saltmere_entry["parent_id"]).to be_nil
      expect(tavern_entry["parent_id"]).to eq(saltmere.id)
    end
  end

  describe "geographic_context" do
    it "returns the player's top-level anchor + nearby top-level locations sorted by distance" do
      saltmere; ice_city
      far_away = Location.create!(name: "Distant", description: "far", x: 200.0, y: 200.0, biome: "lowland")

      result = described_class.new.call({ "name" => "Atlantis" }, context)
      ctx = result["geographic_context"]
      expect(ctx["player_anchor"]["name"]).to eq("Saltmere")
      nearby_names = ctx["nearby"].map { |n| n["name"] }
      expect(nearby_names).to include("City of Ice")
      expect(nearby_names).not_to include("Distant")  # outside NEARBY_RADIUS_UNITS
      expect(ctx["nearby"].first["direction"]).to be_a(String)
      expect(ctx["nearby"].first["approx_minutes"]).to be_a(Integer)
    end

    it "returns nil player_anchor when player has no top-level coordinated ancestor" do
      stub_orphan = Location.create!(name: "Orphan", description: "no coords")
      ctx = Harness::Turn::Context.new(player_location: stub_orphan, game_time: 100)
      result = described_class.new.call({ "name" => "Atlantis" }, ctx)
      expect(result["geographic_context"]["player_anchor"]).to be_nil
      expect(result["geographic_context"]["nearby"]).to eq([])
    end

    it "walks parent chain to find the top-level anchor" do
      saltmere; ice_city
      # tavern is a sublocation of saltmere; its anchor should be Saltmere.
      result = described_class.new.call({ "name" => "Atlantis" }, context)
      expect(result["geographic_context"]["player_anchor"]["name"]).to eq("Saltmere")
    end
  end

  describe "validation" do
    it "rejects an empty name" do
      result = described_class.new.call({ "name" => "  " }, context)
      expect(result["error"]).to match(/name must be/)
    end
  end
end
