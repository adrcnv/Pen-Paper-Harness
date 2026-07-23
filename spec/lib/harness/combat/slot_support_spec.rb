require "rails_helper"

RSpec.describe Harness::Combat::SlotSupport do
  let(:loc) { Location.create!(name: "Yard") }
  let(:hero) {
    Player.create!(
      name: "Hero", location: loc, current_hp: 20, max_hp: 20,
      abilities: [
        { "name" => "Arcane Bolt", "effect_kind" => "damage", "opposed_by" => "dexterity", "uses_remaining" => 4 },
        { "name" => "Shield Up", "effect_kind" => "buff", "uses_remaining" => 2 }
      ]
    )
  }
  let(:foe)  { Npc.create!(name: "Vek", subrole: "marauder", location: loc, current_hp: 18, max_hp: 18) }
  let(:foe2) { Npc.create!(name: "Bor", subrole: "marauder", location: loc, current_hp: 18, max_hp: 18) }

  def state_with(*npcs)
    state = Harness::Combat::State.new
    state.add_combatant(hero.id, side: "player_party")
    npcs.each { |n| state.add_combatant(n.id, side: "marauders") }
    state
  end

  def call_with(args)
    Harness::LLM::ToolCall.new(name: "resolve", args: args)
  end

  describe ".slot_schemas" do
    it "swaps resolve for the combat-narrowed schema (ability_name required, stat mode gone), leaving other tools untouched" do
      resolver = Harness::Resolver.new(
        context: Harness::Turn::Context.new(player_location: loc),
        tools:   Harness::Resolver::NPC_TURN_TOOLS
      )
      schemas = described_class.slot_schemas(resolver)

      resolve = schemas.find { |s| s["name"] == "resolve" }
      expect(resolve.dig("input_schema", "required")).to include("ability_name")
      expect(resolve.dig("input_schema", "properties")).not_to have_key("stat")
      expect(schemas.map { |s| s["name"] }).to include("move_to", "end_turn", "escape")
      expect(schemas.find { |s| s["name"] == "move_to" }).to eq(Harness::Combat::Tools::MoveTo.schema)
    end
  end

  describe ".normalize_resolve_args!" do
    it "binds an owned ability named in the action prose instead of defaulting to a punch" do
      call = call_with({ "actor_id" => hero.id, "action" => "cast arcane bolt at vek", "time_minutes" => 1 })
      described_class.normalize_resolve_args!(call, hero, state_with(foe))
      expect(call.args["ability_name"]).to eq("Arcane Bolt")
      expect(call.args["target_id"]).to eq(foe.id)
    end

    it "still falls back to unarmed_strike when the prose names nothing owned, binding the sole opponent" do
      call = call_with({ "actor_id" => hero.id, "action" => "swing wildly", "time_minutes" => 1 })
      described_class.normalize_resolve_args!(call, hero, state_with(foe))
      expect(call.args["ability_name"]).to eq("unarmed_strike")
      expect(call.args["target_id"]).to eq(foe.id)
    end

    it "leaves the target unbound when several opponents stand (ambiguity stays ambiguous)" do
      call = call_with({ "actor_id" => hero.id, "action" => "cast arcane bolt", "time_minutes" => 1 })
      described_class.normalize_resolve_args!(call, hero, state_with(foe, foe2))
      expect(call.args["ability_name"]).to eq("Arcane Bolt")
      expect(call.args["target_id"]).to be_nil
    end

    it "never target-defaults a buff and never overrides an explicit target" do
      buff = call_with({ "actor_id" => hero.id, "ability_name" => "Shield Up", "action" => "guard up", "time_minutes" => 1 })
      described_class.normalize_resolve_args!(buff, hero, state_with(foe))
      expect(buff.args["target_id"]).to be_nil

      aimed = call_with({ "actor_id" => hero.id, "ability_name" => "Arcane Bolt", "target_id" => foe2.id, "action" => "bolt", "time_minutes" => 1 })
      described_class.normalize_resolve_args!(aimed, hero, state_with(foe, foe2))
      expect(aimed.args["target_id"]).to eq(foe2.id)
    end

    it "skips a depleted ability named in prose and does not bind dead opponents" do
      hero.update!(abilities: [ { "name" => "Arcane Bolt", "effect_kind" => "damage", "opposed_by" => "dexterity", "uses_remaining" => 0 } ])
      foe.update!(current_hp: 0)
      call = call_with({ "actor_id" => hero.id, "action" => "cast arcane bolt at vek", "time_minutes" => 1 })
      described_class.normalize_resolve_args!(call, hero, state_with(foe, foe2))
      expect(call.args["ability_name"]).to eq("unarmed_strike")
      expect(call.args["target_id"]).to eq(foe2.id)  # foe is down — Bor is the sole LIVING opponent
    end
  end
end
