require "rails_helper"

RSpec.describe Harness::Planner do
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

  def context_with(model:, location:)
    Harness::Turn::Context.new(
      player_location: location,
      llm_grunt:       model,
      llm_nuance:      model,
      game_time:       100
    )
  end

  def plan_for(model:, location:, sm:, input:)
    described_class.plan_for(context: context_with(model: model, location: location), scene_manager: sm, input: input)
  end

  describe "happy path" do
    it "parses a valid plan and normalizes steps" do
      body = { "plan" => [ { "runner" => "conversation", "reason" => "ask Tomas", "args" => {} } ] }.to_json
      result = plan_for(model: adapter(body), location: tavern, sm: scene_manager_for(tavern, characters: [ npc ]), input: "ask Tomas about work")

      expect(result["plan"].size).to eq(1)
      expect(result["plan"].first["runner"]).to eq("conversation")
      expect(result["plan"].first).not_to have_key("invalid")
      expect(result["parse_error"]).to be_nil
      expect(result["world"]).to be_a(Hash)
    end

    it "surfaces present characters, items, and nearby locations to the planner" do
      captured = nil
      a = adapter(->(user) { captured = user; { "plan" => [] }.to_json })
      item = Item.create!(name: "smooth locket", location: tavern)
      smithy # touch to create the sibling

      plan_for(model: a, location: tavern, sm: scene_manager_for(tavern, characters: [ npc ], items: [ item ]), input: "look around")

      expect(captured).to include("Tomas")
      expect(captured).to include("smooth locket")
      expect(captured).to include("Oakenford") # parent city in nearby_locations
    end
  end

  describe "collapsing consecutive conversation steps (room-level runner)" do
    it "collapses a multi-addressee turn planned as [conversation, conversation] into one" do
      body = { "plan" => [
        { "runner" => "conversation", "reason" => "address Ingrid" },
        { "runner" => "conversation", "reason" => "address Astrid" }
      ] }.to_json
      result = plan_for(model: adapter(body), location: tavern, sm: scene_manager_for(tavern, characters: [ npc ]), input: "turn to Ingrid... turn to Astrid...")
      expect(result["plan"].map { |s| s["runner"] }).to eq(%w[conversation])
    end

    it "collapses a run of three into one" do
      body = { "plan" => Array.new(3) { { "runner" => "conversation", "reason" => "talk" } } }.to_json
      result = plan_for(model: adapter(body), location: tavern, sm: scene_manager_for(tavern, characters: [ npc ]), input: "talk to everyone")
      expect(result["plan"].map { |s| s["runner"] }).to eq(%w[conversation])
    end

    it "does NOT collapse conversation steps separated by another runner" do
      body = { "plan" => [
        { "runner" => "conversation", "reason" => "ask here" },
        { "runner" => "movement", "reason" => "walk over" },
        { "runner" => "conversation", "reason" => "ask there" }
      ] }.to_json
      result = plan_for(model: adapter(body), location: tavern, sm: scene_manager_for(tavern, characters: [ npc ]), input: "ask, walk, ask")
      expect(result["plan"].map { |s| s["runner"] }).to eq(%w[conversation movement conversation])
    end
  end

  describe "reasoning field" do
    it "captures the planner's reasoning alongside the plan" do
      body = {
        "reasoning" => "The ridge is not in nearby_locations, so it must be created before it can be entered.",
        "plan"      => [ { "runner" => "worldbuilding", "reason" => "make ridge" }, { "runner" => "movement", "reason" => "go" } ]
      }.to_json
      result = plan_for(model: adapter(body), location: tavern, sm: scene_manager_for(tavern), input: "head up to the ridge")

      expect(result["reasoning"]).to match(/must be created before/)
      expect(result["plan"].map { |s| s["runner"] }).to eq(%w[worldbuilding movement])
    end

    it "leaves reasoning nil when the model omits it" do
      body = { "plan" => [ { "runner" => "inspection", "reason" => "look" } ] }.to_json
      result = plan_for(model: adapter(body), location: tavern, sm: scene_manager_for(tavern), input: "look")

      expect(result["reasoning"]).to be_nil
      expect(result["plan"].first["runner"]).to eq("inspection")
    end
  end

  describe "tolerant parsing" do
    it "strips code fences" do
      body = "```json\n{\"plan\": [{\"runner\": \"movement\", \"reason\": \"go\"}]}\n```"
      result = plan_for(model: adapter(body), location: tavern, sm: scene_manager_for(tavern), input: "go to the smithy")
      expect(result["plan"].first["runner"]).to eq("movement")
    end

    it "extracts a JSON object embedded in stray prose" do
      body = "Sure! Here is the plan: {\"plan\": [{\"runner\": \"inspection\", \"reason\": \"look\"}]} hope that helps"
      result = plan_for(model: adapter(body), location: tavern, sm: scene_manager_for(tavern), input: "look")
      expect(result["plan"].first["runner"]).to eq("inspection")
    end

    it "flags an unknown runner without raising" do
      body = { "plan" => [ { "runner" => "teleport", "reason" => "?" } ] }.to_json
      result = plan_for(model: adapter(body), location: tavern, sm: scene_manager_for(tavern), input: "blink away")
      expect(result["plan"].first["invalid"]).to match(/unknown runner/)
    end

    it "captures a parse error on garbage output without raising" do
      result = plan_for(model: adapter("I refuse to answer in JSON."), location: tavern, sm: scene_manager_for(tavern), input: "whatever")
      expect(result["plan"]).to be_nil
      expect(result["parse_error"]).to be_present
    end
  end

  describe "travel destinations" do
    it "surfaces other top-level settlements the player can journey to" do
      Location.create!(name: "Farhold", x: 10.0, y: 10.0, properties: {})
      captured = nil
      a = adapter(->(user) { captured = user; { "plan" => [] }.to_json })
      plan_for(model: a, location: tavern, sm: scene_manager_for(tavern), input: "travel to Farhold")
      expect(captured).to include("Farhold")
    end

    it "excludes wilderness leaves and the player's own city" do
      Location.create!(name: "Bandit Bend", x: 5.0, y: 5.0, properties: { "kind" => "wilderness_leaf" })
      city.update!(x: 1.0, y: 1.0) # give the home city coords so its exclusion is meaningful
      captured = nil
      a = adapter(->(user) { captured = user; { "plan" => [] }.to_json })
      plan_for(model: a, location: tavern, sm: scene_manager_for(tavern), input: "look")

      names = JSON.parse(captured.sub(/\AINPUT:\n/, ""))["travel_destinations"].map { |d| d["name"] }
      expect(names).not_to include("Bandit Bend") # wilderness leaf, not a settlement
      expect(names).not_to include("Oakenford")   # the city the player is already in
    end
  end

  describe "failure isolation" do
    it "captures a raised adapter error instead of propagating" do
      boom = Class.new do
        def complete(system:, user:) = raise "network down"
        def display_model = "boom"
      end.new
      result = plan_for(model: boom, location: tavern, sm: scene_manager_for(tavern), input: "look")
      expect(result["plan"]).to be_nil
      expect(result["parse_error"]).to match(/network down/)
    end
  end
end
