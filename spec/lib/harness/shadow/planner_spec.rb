require "rails_helper"

RSpec.describe Harness::Shadow::Planner do
  let(:city)   { Location.create!(name: "Oakenford") }
  let(:tavern) { Location.create!(name: "The Drowned Rat", parent_id: city.id) }
  let(:smithy) { Location.create!(name: "Smithy", parent_id: city.id) }
  let(:npc)    { Npc.create!(name: "Tomas", subrole: "barkeep", location: tavern, character_class: "commoner") }

  # Minimal adapter double: complete(system:, user:) returns a canned body.
  def adapter(body, model: "fake-model")
    Class.new do
      define_method(:complete) { |system:, user:| body.respond_to?(:call) ? body.call(user) : body }
      define_method(:display_model) { model }
    end.new
  end

  def scene_manager_for(location, characters: [], items: [], narrations: [])
    snap = Struct.new(:location, :present_characters, :present_items).new(location, characters, items)
    active = Harness::Scene::Active.new(
      location:             location,
      snapshot:             snap,
      narrations:           narrations,
      internal_state:       {},
      agendas:              {},
      extras:               [],
      entered_at_game_time: 0
    )
    Struct.new(:active).new(active)
  end

  def context_with(grunt:, nuance: nil, location:)
    Harness::Turn::Context.new(
      player_location: location,
      llm_grunt:       grunt,
      llm_nuance:      nuance || grunt,
      game_time:       100
    )
  end

  describe "happy path" do
    it "parses a valid plan and normalizes steps" do
      body = { "plan" => [ { "runner" => "conversation", "reason" => "ask Tomas", "args" => {} } ] }.to_json
      ctx  = context_with(grunt: adapter(body), location: tavern)
      sm   = scene_manager_for(tavern, characters: [ npc ])

      result = described_class.run(context: ctx, scene_manager: sm, input: "ask Tomas about work")

      plan = result["plans"]["shared"]["plan"]
      expect(plan.size).to eq(1)
      expect(plan.first["runner"]).to eq("conversation")
      expect(plan.first).not_to have_key("invalid")
      expect(result["plans"]["shared"]["parse_error"]).to be_nil
    end

    it "surfaces present characters, items, and nearby locations to the planner" do
      captured = nil
      a = adapter(->(user) { captured = user; { "plan" => [] }.to_json })
      ctx = context_with(grunt: a, location: tavern)
      item = Item.create!(name: "smooth locket", location: tavern)
      sm  = scene_manager_for(tavern, characters: [ npc ], items: [ item ])

      described_class.run(context: ctx, scene_manager: sm, input: "look around")

      expect(captured).to include("Tomas")
      expect(captured).to include("smooth locket")
      # nearby_locations should include the sibling smithy and parent city.
      smithy # touch to create
      expect(captured).to include("Oakenford")
    end
  end

  describe "tolerant parsing" do
    it "strips code fences" do
      body = "```json\n{\"plan\": [{\"runner\": \"movement\", \"reason\": \"go\"}]}\n```"
      ctx  = context_with(grunt: adapter(body), location: tavern)
      sm   = scene_manager_for(tavern)

      result = described_class.run(context: ctx, scene_manager: sm, input: "go to the smithy")
      expect(result["plans"]["shared"]["plan"].first["runner"]).to eq("movement")
    end

    it "extracts a JSON object embedded in stray prose" do
      body = "Sure! Here is the plan: {\"plan\": [{\"runner\": \"inspection\", \"reason\": \"look\"}]} hope that helps"
      ctx  = context_with(grunt: adapter(body), location: tavern)
      sm   = scene_manager_for(tavern)

      result = described_class.run(context: ctx, scene_manager: sm, input: "look")
      expect(result["plans"]["shared"]["plan"].first["runner"]).to eq("inspection")
    end

    it "flags an unknown runner without raising" do
      body = { "plan" => [ { "runner" => "teleport", "reason" => "?" } ] }.to_json
      ctx  = context_with(grunt: adapter(body), location: tavern)
      sm   = scene_manager_for(tavern)

      result = described_class.run(context: ctx, scene_manager: sm, input: "blink away")
      expect(result["plans"]["shared"]["plan"].first["invalid"]).to match(/unknown runner/)
    end

    it "captures a parse error on garbage output without raising" do
      ctx = context_with(grunt: adapter("I refuse to answer in JSON."), location: tavern)
      sm  = scene_manager_for(tavern)

      result = described_class.run(context: ctx, scene_manager: sm, input: "whatever")
      expect(result["plans"]["shared"]["plan"]).to be_nil
      expect(result["plans"]["shared"]["parse_error"]).to be_present
    end
  end

  describe "two-tier diffing" do
    it "calls both tiers when grunt and nuance are distinct adapters" do
      grunt  = adapter({ "plan" => [ { "runner" => "agentic", "reason" => "g" } ] }.to_json, model: "small")
      nuance = adapter({ "plan" => [ { "runner" => "conversation", "reason" => "n" } ] }.to_json, model: "big")
      ctx    = context_with(grunt: grunt, nuance: nuance, location: tavern)
      sm     = scene_manager_for(tavern, characters: [ npc ])

      result = described_class.run(context: ctx, scene_manager: sm, input: "ask Tomas")

      expect(result["plans"].keys).to contain_exactly("grunt", "nuance")
      expect(result["plans"]["grunt"]["plan"].first["runner"]).to eq("agentic")
      expect(result["plans"]["nuance"]["plan"].first["runner"]).to eq("conversation")
    end

    it "collapses to a single 'shared' entry when both tiers are the same adapter" do
      shared = adapter({ "plan" => [] }.to_json)
      ctx    = context_with(grunt: shared, nuance: shared, location: tavern)
      sm     = scene_manager_for(tavern)

      result = described_class.run(context: ctx, scene_manager: sm, input: "look")
      expect(result["plans"].keys).to contain_exactly("shared")
    end
  end

  describe "offline replay path" do
    it "plans from an injected world + adapters with no live context" do
      captured = nil
      a = adapter(->(user) { captured = user; { "plan" => [ { "runner" => "movement", "reason" => "go" } ] }.to_json })
      world = {
        "present_characters" => [ { "id" => 9, "name" => "Greta", "subrole" => "barkeep" } ],
        "present_items"      => [],
        "nearby_locations"   => [ { "id" => 2, "name" => "Docks", "rel" => "sibling" } ],
        "recent_history"     => []
      }

      result = described_class.run_offline(
        input:            "go to the docks",
        world:            world,
        adapters_by_tier: { "grunt" => a }
      )

      expect(result["plans"]["grunt"]["plan"].first["runner"]).to eq("movement")
      expect(captured).to include("Docks")
      expect(captured).to include("Greta")
      expect(result["world"]).to eq(world)
    end

    it "diffs two tiers offline" do
      g = adapter({ "plan" => [ { "runner" => "agentic", "reason" => "g" } ] }.to_json)
      n = adapter({ "plan" => [ { "runner" => "movement", "reason" => "n" } ] }.to_json)
      result = described_class.run_offline(
        input:            "go to the docks",
        world:            { "nearby_locations" => [ { "id" => 2, "name" => "Docks" } ] },
        adapters_by_tier: { "grunt" => g, "nuance" => n }
      )
      expect(result["plans"].keys).to contain_exactly("grunt", "nuance")
    end
  end

  describe "failure isolation" do
    it "captures a raised adapter error per-tier instead of propagating" do
      boom = Class.new do
        def complete(system:, user:) = raise "network down"
        def display_model = "boom"
      end.new
      ctx = context_with(grunt: boom, location: tavern)
      sm  = scene_manager_for(tavern)

      result = described_class.run(context: ctx, scene_manager: sm, input: "look")
      expect(result["plans"]["shared"]["plan"]).to be_nil
      expect(result["plans"]["shared"]["parse_error"]).to match(/network down/)
    end
  end
end
