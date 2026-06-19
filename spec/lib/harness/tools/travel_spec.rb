require "rails_helper"

RSpec.describe Harness::Tools::Travel do
  let(:saltmere)  { Location.create!(name: "Saltmere",  description: "harbor",   x: 10.0, y: 10.0, biome: "lowland") }
  let(:saltkeep)  { Location.create!(name: "Saltkeep",  description: "north city", x: 80.0, y: 10.0, biome: "lowland") }
  let(:wayshrine) { Location.create!(name: "Wayshrine", description: "midway",   x: 45.0, y: 10.0, biome: "lowland") }
  let(:context)   { Harness::Turn::Context.new(player_location: saltmere, game_time: 100) }

  describe "validation" do
    it "rejects when destination_id is missing" do
      result = described_class.new.call({}, context)
      expect(result["error"]).to match(/destination_id required/)
    end

    it "rejects when destination doesn't exist" do
      result = described_class.new.call({ "destination_id" => 99_999 }, context)
      expect(result["error"]).to match(/no location with id=99999/)
    end

    it "rejects when destination has no coordinates (e.g., a sublocation)" do
      tavern = Location.create!(name: "Tavern", parent: saltmere)
      result = described_class.new.call({ "destination_id" => tavern.id }, context)
      expect(result["error"]).to match(/top-level Location with coordinates/)
    end

    it "rejects when player is not at a top-level coordinated location" do
      orphan = Location.create!(name: "Orphan")
      ctx = Harness::Turn::Context.new(player_location: orphan, game_time: 100)
      result = described_class.new.call({ "destination_id" => saltkeep.id }, ctx)
      expect(result["error"]).to match(/not at a top-level coordinated location/)
    end

    it "rejects when player is already at the destination" do
      saltmere; saltkeep
      result = described_class.new.call({ "destination_id" => saltmere.id }, context)
      expect(result["error"]).to match(/already at/)
    end
  end

  describe "cold arrival (no encounters, no snap targets in the way)" do
    it "moves the player to the destination and reports outcome=arrived" do
      saltmere; saltkeep
      result = described_class.new.call({ "destination_id" => saltkeep.id }, context)
      expect(result["outcome"]).to eq("arrived")
      expect(result["destination"]).to include("name" => "Saltkeep")
      expect(context.player_location).to eq(saltkeep)
      expect(context.scene_dirty).to be(true)
    end

    it "advances game_time by the travel cost" do
      saltmere; saltkeep
      expect {
        described_class.new.call({ "destination_id" => saltkeep.id }, context)
      }.to change { context.game_time }.by_at_least(70 * Harness::Tools::Travel::MIN_PER_DISTANCE * 0.9)
    end

    it "persists the player's location to the DB" do
      saltmere; saltkeep
      Player.create!(name: "Hero", location: saltmere)
      described_class.new.call({ "destination_id" => saltkeep.id }, context)
      expect(Player.first.location).to eq(saltkeep)
    end

    it "wipes the journey row on arrival (no resumable journey after)" do
      saltmere; saltkeep
      described_class.new.call({ "destination_id" => saltkeep.id }, context)
      expect(Journey.active).to be_nil
    end

    it "relocates flagged followers to the destination on arrival" do
      saltmere; saltkeep
      Player.create!(name: "Hero", location: saltmere)
      elara = Npc.create!(name: "Elara", location: saltmere, character_class: "fighter",
                          properties: { "following_player" => true })
      bystander = Npc.create!(name: "Drunk", location: saltmere, character_class: "commoner",
                              properties: { "following_player" => false })

      described_class.new.call({ "destination_id" => saltkeep.id }, context)

      expect(elara.reload.location_id).to eq(saltkeep.id)
      expect(bystander.reload.location_id).to eq(saltmere.id)
    end
  end

  describe "snap to a known location passed along the way" do
    it "snaps to the wayshrine instead of completing arrival" do
      saltmere; saltkeep; wayshrine  # wayshrine sits roughly on the line
      result = described_class.new.call({ "destination_id" => saltkeep.id }, context)
      expect(result["outcome"]).to eq("snapped")
      expect(result["snapped_to"]).to include("name" => "Wayshrine")
      expect(context.player_location).to eq(wayshrine)
      expect(context.scene_dirty).to be(true)
    end

    it "leaves the journey row populated with the destination so resume works" do
      saltmere; saltkeep; wayshrine
      described_class.new.call({ "destination_id" => saltkeep.id }, context)
      expect(Journey.active).not_to be_nil
      expect(Journey.active.destination_id).to eq(saltkeep.id)
    end

    it "never snaps backward to a neighbor that sits behind the start" do
      # Regression: "continue traveling to Iron Pass" snapped the player BACK to
      # the city they'd just left, because that city was within SNAP_RADIUS of
      # the first tiny step even though it was FARTHER from the destination.
      # Real coords from the playthrough.
      crossing  = Location.create!(name: "Crossing",  x: 91.1, y: 49.5, biome: "lowland")
      iron_pass = Location.create!(name: "Iron Pass", x: 86.6, y: 29.1, biome: "lowland")
      osmere    = Location.create!(name: "Osmere",    x: 91.5, y: 51.5, biome: "lowland") # behind the start
      ctx = Harness::Turn::Context.new(player_location: crossing, game_time: 100)

      result = described_class.new.call({ "destination_id" => iron_pass.id }, ctx)

      # Osmere is closer to the start than to the destination → filtered out as a
      # snap target. With no forward snap candidate, the trip simply arrives.
      expect(ctx.player_location).not_to eq(osmere)
      expect(result["snapped_to"]).to be_nil
      expect(result["outcome"]).to eq("arrived")
      expect(ctx.player_location).to eq(iron_pass)
    end

    it "does not snap to the destination itself (arrival path handles that)" do
      # Place a tiny location very close to the destination — it should NOT
      # snap there before arriving (destination is excluded from snap candidates).
      saltmere
      saltkeep
      Location.create!(name: "Almost There", x: 79.0, y: 10.0, biome: "lowland")
      result = described_class.new.call({ "destination_id" => saltkeep.id }, context)
      expect(result["outcome"]).to eq("snapped")
      expect(result["snapped_to"]["name"]).to eq("Almost There")
      # Then a second call from "Almost There" finishes the trip.
      context.player_location = Location.find_by!(name: "Almost There")
      result2 = described_class.new.call({ "destination_id" => saltkeep.id }, context)
      expect(result2["outcome"]).to eq("arrived")
    end
  end

  describe "encounters mid-route" do
    # Force the encounter dice to always fire by setting ENCOUNTER_RATE high
    # via a stubbed rng. Snap precedence still wins, so we set the route well
    # away from any other known location.
    let(:always_encounter_rng) {
      Random.new.tap { |r| allow(r).to receive(:rand).and_return(0.0) }
    }

    let(:place_llm) {
      StubLLM.new { |_|
        { "name" => "the Sunken Yarrow Shrine", "description" => "A low stone shrine half-swallowed by reeds, the offering bowl scoured clean by rain." }.to_json
      }
    }

    let(:context_with_grunt) {
      Harness::Turn::Context.new(player_location: saltmere, game_time: 100, llm_grunt: place_llm)
    }

    it "spawns a wilderness_leaf at the cursor and stops the journey on encounter" do
      saltmere; saltkeep
      tool = described_class.new(rng: always_encounter_rng)
      result = tool.call({ "destination_id" => saltkeep.id }, context_with_grunt)
      expect(result["outcome"]).to eq("encounter")
      expect(result["place"]["name"]).to eq("the Sunken Yarrow Shrine")
      expect(context_with_grunt.player_location.name).to eq("the Sunken Yarrow Shrine")
      expect(context_with_grunt.scene_dirty).to be(true)
    end

    it "tags the spawned location as wilderness_leaf with encounter_type" do
      saltmere; saltkeep
      described_class.new(rng: always_encounter_rng).call({ "destination_id" => saltkeep.id }, context_with_grunt)
      leaf = Location.find_by(name: "the Sunken Yarrow Shrine")
      expect(leaf.properties["kind"]).to eq("wilderness_leaf")
      expect(leaf.properties["encounter_type"]).to satisfy { |t| %w[social discovery combat].include?(t) }
    end

    it "sets cooldown_until_game_time on the journey row so the next call doesn't immediately re-fire" do
      saltmere; saltkeep
      described_class.new(rng: always_encounter_rng).call({ "destination_id" => saltkeep.id }, context_with_grunt)
      journey = Journey.active
      expect(journey).not_to be_nil
      expect(journey.cooldown_until_game_time).to be > 0
    end

    it "advances game_time by the segment cost when encounter fires" do
      saltmere; saltkeep
      expect {
        described_class.new(rng: always_encounter_rng).call({ "destination_id" => saltkeep.id }, context_with_grunt)
      }.to change { context_with_grunt.game_time }.by_at_least(1)
    end

    it "leaves the journey active so resume works" do
      saltmere; saltkeep
      described_class.new(rng: always_encounter_rng).call({ "destination_id" => saltkeep.id }, context_with_grunt)
      expect(Journey.active.destination_id).to eq(saltkeep.id)
    end

    it "skips encounter dice silently when llm_grunt is nil (cold-arrival fallback)" do
      saltmere; saltkeep
      no_grunt = Harness::Turn::Context.new(player_location: saltmere, game_time: 100)
      result = described_class.new(rng: always_encounter_rng).call({ "destination_id" => saltkeep.id }, no_grunt)
      expect(result["outcome"]).to eq("arrived")
    end
  end

  describe "resume" do
    it "resumes from cursor when called again with the same destination_id" do
      saltmere; saltkeep; wayshrine
      described_class.new.call({ "destination_id" => saltkeep.id }, context)  # snaps at wayshrine
      result = described_class.new.call({ "destination_id" => saltkeep.id }, context)
      expect(result["outcome"]).to eq("arrived")
    end

    it "discards the existing journey when called with a different destination_id" do
      saltmere; saltkeep; wayshrine
      other_dest = Location.create!(name: "Eastpost", x: 10.0, y: 80.0, biome: "lowland")
      described_class.new.call({ "destination_id" => saltkeep.id }, context)  # snap at wayshrine
      expect(Journey.active.destination_id).to eq(saltkeep.id)
      # Now redirect to Eastpost — the saltkeep journey should be wiped.
      described_class.new.call({ "destination_id" => other_dest.id }, context)
      # After this call we either snapped or arrived at eastpost; either way the
      # cached journey to saltkeep is gone.
      active = Journey.active
      expect(active).to satisfy { |j| j.nil? || j.destination_id == other_dest.id }
    end
  end
end
