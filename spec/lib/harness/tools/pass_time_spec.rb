require "rails_helper"

RSpec.describe Harness::Tools::PassTime do
  let(:tool)    { described_class.new }
  let(:loc)     { Location.create!(name: "Tavern") }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 1000) }

  describe "#call" do
    it "advances game_time by duration_minutes" do
      result = tool.call({ "intent" => "rest", "duration_minutes" => 480 }, context)
      expect(context.game_time).to eq(1480)
      expect(result["before"]).to eq(1000)
      expect(result["after"]).to eq(1480)
      expect(result["intent"]).to eq("rest")
      expect(result["duration_minutes"]).to eq(480)
    end

    it "errors on missing intent" do
      result = tool.call({ "duration_minutes" => 60 }, context)
      expect(result).to have_key("error")
      expect(context.game_time).to eq(1000)
    end

    it "errors on invalid intent" do
      result = tool.call({ "intent" => "vibe", "duration_minutes" => 60 }, context)
      expect(result).to have_key("error")
    end

    it "errors on missing duration_minutes" do
      result = tool.call({ "intent" => "rest" }, context)
      expect(result).to have_key("error")
    end

    it "errors on zero or negative duration" do
      expect(tool.call({ "intent" => "rest", "duration_minutes" => 0  }, context)).to have_key("error")
      expect(tool.call({ "intent" => "rest", "duration_minutes" => -5 }, context)).to have_key("error")
    end

    it "sets scene_dirty when crossing threshold" do
      active = Harness::Scene::Active.new(
        location: loc, snapshot: nil, narrations: [], internal_state: {},
        entered_at_game_time: 1000
      )
      context.active_scene = active

      tool.call({ "intent" => "sleep", "duration_minutes" => 480 }, context)
      expect(context.scene_dirty).to be(true)
      # The result echoes scene_dirty so the LLM knows the next turn will rebuild.
      result = tool.call({ "intent" => "wait", "duration_minutes" => 5 }, context)
      expect(result["scene_dirty"]).to be(true)
    end
  end

  describe "restorative refresh" do
    let!(:player) {
      Player.create!(
        name: "Hero", location: loc, character_class: "mage", level: 5,
        constitution: 14, max_hp: 30, current_hp: 12,
        abilities: [
          { "name" => "Arcane Bolt", "uses_per_rest" => 4, "uses_remaining" => 1, "effect_kind" => "damage" },
          { "name" => "Frost Sphere", "uses_per_rest" => 2, "uses_remaining" => 0, "effect_kind" => "damage" }
        ]
      )
    }

    it "rest refreshes player ability uses_remaining to uses_per_rest" do
      tool.call({ "intent" => "rest", "duration_minutes" => 480 }, context)
      uses = player.reload.abilities.map { |a| a["uses_remaining"] }
      expect(uses).to eq([ 4, 2 ])
    end

    it "rest restores current_hp to max_hp" do
      tool.call({ "intent" => "sleep", "duration_minutes" => 480 }, context)
      expect(player.reload.current_hp).to eq(player.max_hp)
    end

    it "wait does NOT refresh uses or HP" do
      tool.call({ "intent" => "wait", "duration_minutes" => 480 }, context)
      uses = player.reload.abilities.map { |a| a["uses_remaining"] }
      expect(uses).to eq([ 1, 0 ])
      expect(player.reload.current_hp).to eq(12)
    end

    it "linger does NOT refresh" do
      tool.call({ "intent" => "linger", "duration_minutes" => 480 }, context)
      expect(player.reload.current_hp).to eq(12)
    end

    it "result echoes refreshed=true on rest, false on wait" do
      out_rest = tool.call({ "intent" => "rest", "duration_minutes" => 60 }, context)
      out_wait = tool.call({ "intent" => "wait", "duration_minutes" => 60 }, context)
      expect(out_rest["refreshed"]).to be(true)
      expect(out_wait["refreshed"]).to be(false)
    end
  end

  describe "schema" do
    it "lists intent and duration_minutes as required" do
      schema = described_class.schema
      expect(schema["input_schema"]["required"]).to contain_exactly("intent", "duration_minutes")
    end
  end
end
