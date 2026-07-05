require "rails_helper"

RSpec.describe Harness::Combat::PlayerTurn do
  let(:loc) { Location.create!(name: "Tavern") }
  let!(:player) {
    Player.create!(
      name: "Mud", location: loc, dexterity: 14, strength: 12, current_hp: 20, max_hp: 20,
      abilities: [ {
        "name" => "Sacred Strike", "stat" => "strength", "opposed_by" => "dexterity",
        "effect_kind" => "damage", "damage_dice" => "1d8", "uses_remaining" => 3,
        "range" => "close", "tags" => [ "martial" ], "requires_tags" => []
      } ]
    )
  }
  let!(:vek) {
    Npc.create!(
      name: "Vek", subrole: "marauder", location: loc,
      strength: 14, dexterity: 12, current_hp: 18, max_hp: 18
    )
  }

  def make_combat_context
    snap   = Harness::Scene::Snapshot.new(location: loc, present_characters: [ player, vek ], present_corpses: [], present_items: [])
    active = Harness::Scene::Active.new(location: loc, snapshot: snap, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
    active.start_combat!
    active.combat.add_combatant(player.id, side: "player_party")
    active.combat.add_combatant(vek.id,    side: "marauders")
    active.combat.initiative = [ player.id, vek.id ]  # player's slot
    ctx = Harness::Turn::Context.new(player_location: loc, game_time: 0)
    ctx.active_scene = active
    ctx
  end

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

  it "translates an attack input into resolve, with the actor forced to the player" do
    ctx = make_combat_context
    ctx.active_scene.combat.engage!(player.id, vek.id)
    allow(::Harness::Dice).to receive(:check).and_return(
      ::Harness::Dice::Outcome.new(result: "success", margin: "clear", critical: false, roll: 17, against: 12)
    )

    adapter = OneShotAdapter.new(tool: "resolve", args: {
      "actor_id" => vek.id,  # model wrote the wrong actor — must be overridden
      "ability_name" => "Sacred Strike", "target_id" => vek.id, "action" => "strike", "time_minutes" => 1
    })
    call, result = described_class.run(player: player, input: "I strike Vek down", scene: ctx.active_scene, adapter: adapter, context: ctx)

    expect(call.args["actor_id"]).to eq(player.id)
    expect(result["error"]).to be_nil
    expect(adapter.last_user).to include("I strike Vek down")   # input is in the payload
    expect(ctx.active_scene.combat.acted?(player.id)).to be(true)
  end

  it "returns nil and leaves the slot FRESH when the model emits no call (non-combat input)" do
    ctx = make_combat_context
    empty_adapter = Class.new do
      def start_turn(system:, user:, tools:); Harness::LLM::FakeTurn.new([]); end
    end.new

    out = described_class.run(player: player, input: "what is happening?", scene: ctx.active_scene, adapter: empty_adapter, context: ctx)
    expect(out).to be_nil
    expect(ctx.active_scene.combat.acted?(player.id)).to be(false)
    expect(ctx.active_scene.combat.moved?(player.id)).to be(false)
  end

  it "auto-engages before a close-range ability instead of wasting the slot" do
    ctx = make_combat_context   # NOT engaged — Sacred Strike is close-range
    allow(::Harness::Dice).to receive(:check).and_return(
      ::Harness::Dice::Outcome.new(result: "success", margin: "clear", critical: false, roll: 17, against: 12)
    )

    adapter = OneShotAdapter.new(tool: "resolve", args: {
      "ability_name" => "Sacred Strike", "target_id" => vek.id, "action" => "strike", "time_minutes" => 1
    })
    _call, result = described_class.run(player: player, input: "cut him down", scene: ctx.active_scene, adapter: adapter, context: ctx)

    expect(result["error"]).to be_nil
    expect(ctx.active_scene.combat.engaged_with_of(player.id)).to eq(vek.id)
  end

  it "records a deliberate pass as end_turn (slot spent)" do
    ctx = make_combat_context
    adapter = OneShotAdapter.new(tool: "end_turn", args: { "actor_id" => player.id })

    call, result = described_class.run(player: player, input: "I hold my ground and wait", scene: ctx.active_scene, adapter: adapter, context: ctx)
    expect(call.name).to eq("end_turn")
    expect(result["error"]).to be_nil
    expect(ctx.active_scene.combat.acted?(player.id)).to be(true)
  end

  it "returns nil without an adapter (headless path)" do
    ctx = make_combat_context
    expect(described_class.run(player: player, input: "attack", scene: ctx.active_scene, adapter: nil, context: ctx)).to be_nil
  end
end
