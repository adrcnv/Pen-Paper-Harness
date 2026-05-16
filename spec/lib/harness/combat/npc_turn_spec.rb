require "rails_helper"

RSpec.describe Harness::Combat::NpcTurn do
  let(:loc)    { Location.create!(name: "Tavern") }
  let!(:player) { Player.create!(name: "Mud",  location: loc, dexterity: 14, strength: 12, current_hp: 20, max_hp: 20) }
  let!(:vek)    {
    Npc.create!(
      name: "Vek", subrole: "marauder", location: loc,
      strength: 14, dexterity: 12, constitution: 12, intelligence: 8, wisdom: 8, charisma: 6,
      current_hp: 18, max_hp: 18,
      properties: { "personality" => "aggressive" },
      abilities: [ {
        "name" => "Heavy Strike", "stat" => "strength", "opposed_by" => "dexterity",
        "effect_kind" => "damage", "damage_dice" => "1d8", "uses_remaining" => 3,
        "range" => "close", "tags" => [ "martial" ], "requires_tags" => []
      } ]
    )
  }

  def make_combat_context
    Harness::Scene::Assembler
    snap   = Harness::Scene::Snapshot.new(location: loc, present_characters: [ player, vek ], present_corpses: [], present_items: [])
    active = Harness::Scene::Active.new(location: loc, snapshot: snap, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
    active.start_combat!
    active.combat.add_combatant(player.id, side: "player_party")
    active.combat.add_combatant(vek.id,    side: "marauders")
    active.combat.initiative = [ vek.id, player.id ]  # vek's slot
    ctx = Harness::Turn::Context.new(player_location: loc, game_time: 0)
    ctx.active_scene = active
    ctx
  end

  # Minimal adapter for one start_turn call returning the supplied tool call.
  class OneShotAdapter
    attr_reader :last_user
    def initialize(tool:, args:)
      @tool = tool; @args = args
    end
    def start_turn(system:, user:, tools:)
      @last_user = user
      Harness::LLM::FakeTurn.new([ { tool: @tool, args: @args } ])
    end
  end

  it "dispatches the LLM-chosen tool call through the resolver" do
    ctx = make_combat_context
    ctx.active_scene.combat.engage!(vek.id, player.id)
    allow(::Harness::Dice).to receive(:check).and_return(
      ::Harness::Dice::Outcome.new(result: "success", margin: "clear", critical: false, roll: 17, against: 14)
    )
    allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(5)

    adapter = OneShotAdapter.new(tool: "resolve", args: { "actor_id" => vek.id, "ability_name" => "Heavy Strike", "target_id" => player.id, "action" => "strike", "time_minutes" => 1 })
    out = described_class.run(npc: vek, scene: ctx.active_scene, adapter: adapter, context: ctx)
    expect(out["tool"]).to eq("resolve")
    expect(out["result"]["outcome"]).to eq("success")
  end

  it "force-rewrites actor_id to the current NPC if the LLM picks wrong" do
    ctx = make_combat_context
    ctx.active_scene.combat.engage!(vek.id, player.id)
    allow(::Harness::Dice).to receive(:check).and_return(
      ::Harness::Dice::Outcome.new(result: "success", margin: "clear", critical: false, roll: 17, against: 14)
    )
    allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(5)

    # LLM puts the player's id as actor_id by mistake; module should rewrite.
    adapter = OneShotAdapter.new(tool: "resolve", args: { "actor_id" => player.id, "ability_name" => "Heavy Strike", "target_id" => player.id, "action" => "strike", "time_minutes" => 1 })
    out = described_class.run(npc: vek, scene: ctx.active_scene, adapter: adapter, context: ctx)
    expect(out["args"]["actor_id"]).to eq(vek.id)
  end

  it "auto-end_turns when the LLM emits no tool call" do
    ctx = make_combat_context
    empty_adapter = Class.new do
      def start_turn(system:, user:, tools:); Harness::LLM::FakeTurn.new([]); end
    end.new
    out = described_class.run(npc: vek, scene: ctx.active_scene, adapter: empty_adapter, context: ctx)
    expect(out["tool"]).to eq("end_turn")
    expect(out["auto"]).to be(true)
    expect(ctx.active_scene.combat.slot_complete?(vek.id)).to be(true)
  end

  describe "auto-engage retry on close-range error" do
    let(:ctx) { make_combat_context }

    before do
      # vek and player both at "near" — no engagement edge yet. Close-range
      # ability will hit the range gate.
      allow(::Harness::Dice).to receive(:check).and_return(
        ::Harness::Dice::Outcome.new(result: "success", margin: "clear", critical: false, roll: 17, against: 11)
      )
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(5)
    end

    it "moves to engaged when the LLM picks a close ability at near" do
      state = ctx.active_scene.combat
      expect(state.position_of(vek.id)).to eq("near")
      expect(state.engaged_with_of(vek.id)).to be_nil

      adapter = OneShotAdapter.new(tool: "resolve",
        args: { "actor_id" => vek.id, "ability_name" => "Heavy Strike", "target_id" => player.id, "action" => "strike", "time_minutes" => 1 })

      out = described_class.run(npc: vek, scene: ctx.active_scene, adapter: adapter, context: ctx)

      # Resolve succeeded after the auto-move.
      expect(out["result"]["outcome"]).to eq("success")
      expect(out["result"]["error"]).to be_nil
      # Move token was spent; engagement edge created.
      expect(state.moved?(vek.id)).to be(true)
      expect(state.engaged_with_of(vek.id)).to eq(player.id)
      expect(state.position_of(vek.id)).to eq("engaged")
    end

    it "does NOT auto-engage when move token already spent (slot stays errored)" do
      state = ctx.active_scene.combat
      state.mark_moved!(vek.id)  # simulate a prior move_to this round

      adapter = OneShotAdapter.new(tool: "resolve",
        args: { "actor_id" => vek.id, "ability_name" => "Heavy Strike", "target_id" => player.id, "action" => "strike", "time_minutes" => 1 })

      out = described_class.run(npc: vek, scene: ctx.active_scene, adapter: adapter, context: ctx)
      expect(out["result"]["error"]).to match(/melee range \(close\)/)
      expect(state.engaged_with_of(vek.id)).to be_nil
    end
  end

  describe "defensive resolve normalization" do
    let(:ctx) { make_combat_context }

    before do
      ctx.active_scene.combat.engage!(vek.id, player.id)
      allow(::Harness::Dice).to receive(:check).and_return(
        ::Harness::Dice::Outcome.new(result: "success", margin: "clear", critical: false, roll: 14, against: 11)
      )
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(3)
    end

    it "rewrites bare resolve (no stat, no ability_name) to unarmed_strike" do
      adapter = OneShotAdapter.new(tool: "resolve",
        args: { "actor_id" => vek.id, "action" => "swing wildly", "target_id" => player.id, "time_minutes" => 1 })
      out = described_class.run(npc: vek, scene: ctx.active_scene, adapter: adapter, context: ctx)
      expect(out["args"]["ability_name"]).to eq("unarmed_strike")
      expect(out["result"]["error"]).to be_nil
    end

    it "rewrites a depleted ability_name to unarmed_strike" do
      vek.update!(abilities: [
        { "name" => "Heavy Strike", "stat" => "strength", "opposed_by" => "dexterity",
          "effect_kind" => "damage", "damage_dice" => "1d8", "uses_remaining" => 0,
          "range" => "close", "tags" => [ "martial" ], "requires_tags" => [] }
      ])
      adapter = OneShotAdapter.new(tool: "resolve",
        args: { "actor_id" => vek.id, "ability_name" => "Heavy Strike", "action" => "press the attack",
                "target_id" => player.id, "time_minutes" => 1 })
      out = described_class.run(npc: vek, scene: ctx.active_scene, adapter: adapter, context: ctx)
      expect(out["args"]["ability_name"]).to eq("unarmed_strike")
      expect(out["result"]["error"]).to be_nil
    end

    it "fixes an unrecognized stat to strength" do
      adapter = OneShotAdapter.new(tool: "resolve",
        args: { "actor_id" => vek.id, "stat" => "luck", "action" => "shove",
                "target_id" => player.id, "time_minutes" => 1 })
      out = described_class.run(npc: vek, scene: ctx.active_scene, adapter: adapter, context: ctx)
      expect(out["args"]["stat"]).to eq("strength")
      expect(out["result"]["error"]).to be_nil
    end

    it "leaves a valid call alone" do
      adapter = OneShotAdapter.new(tool: "resolve",
        args: { "actor_id" => vek.id, "ability_name" => "Heavy Strike", "action" => "strike",
                "target_id" => player.id, "time_minutes" => 1 })
      out = described_class.run(npc: vek, scene: ctx.active_scene, adapter: adapter, context: ctx)
      expect(out["args"]["ability_name"]).to eq("Heavy Strike")
    end
  end

  it "puts NPC name, HP, allies, hostiles, and personality in the user payload" do
    ctx = make_combat_context
    adapter = OneShotAdapter.new(tool: "end_turn", args: { "actor_id" => vek.id })
    described_class.run(npc: vek, scene: ctx.active_scene, adapter: adapter, context: ctx)
    expect(adapter.last_user).to include("Vek")
    expect(adapter.last_user).to include("aggressive")
    expect(adapter.last_user).to include("Heavy Strike")
    expect(adapter.last_user).to include("Mud") # player in hostiles
  end
end
