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

    def active_scene
      Harness::Scene::Active.new(
        location: loc, snapshot: nil, narrations: [], internal_state: {},
        entered_at_game_time: 1000
      )
    end

    it "sets scene_dirty for a substantial skip (>= threshold) — an explicit, player-chosen rebuild" do
      context.active_scene = active_scene
      result = tool.call({ "intent" => "sleep", "duration_minutes" => 480 }, context)
      expect(context.scene_dirty).to be(true)
      expect(result["scene_dirty"]).to be(true)
    end

    it "does NOT set scene_dirty for a short skip (< threshold) — a quick wait shouldn't whiplash the scene" do
      context.active_scene = active_scene
      result = tool.call({ "intent" => "wait", "duration_minutes" => 5 }, context)
      expect(context.scene_dirty).to be(false)
      expect(result["scene_dirty"]).to be(false)
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

    it "practice of 2+ hours pays the flat XP award ONCE per rest cycle; a rest re-arms it" do
      out = tool.call({ "intent" => "practice", "duration_minutes" => 180 }, context)
      expect(out["practice_xp"]).to eq(described_class::PRACTICE_XP)
      xp_after_first = player.reload.xp

      # Second session same cycle: clock moves, no award — the grinder door stays shut.
      again = tool.call({ "intent" => "practice", "duration_minutes" => 180 }, context)
      expect(again["practice_xp"]).to be_nil
      expect(player.reload.xp).to eq(xp_after_first)

      tool.call({ "intent" => "rest", "duration_minutes" => 480 }, context)
      rearmed = tool.call({ "intent" => "practice", "duration_minutes" => 120 }, context)
      expect(rearmed["practice_xp"]).to eq(described_class::PRACTICE_XP)
    end

    it "a short practice session moves the clock but pays nothing" do
      out = tool.call({ "intent" => "practice", "duration_minutes" => 30 }, context)
      expect(out["practice_xp"]).to be_nil
      expect(out["after"]).to eq(1030)
      expect(player.reload.properties).not_to have_key("practiced_since_rest")
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
