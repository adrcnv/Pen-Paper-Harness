require "rails_helper"

RSpec.describe Harness::Combat::Tools::Escape do
  let(:city)   { Location.create!(name: "Saltmere") }
  let(:tavern) { Location.create!(name: "Tavern", parent: city) }
  let!(:player) { Player.create!(name: "Mud", location: tavern, dexterity: 14, strength: 10, constitution: 12, intelligence: 10, wisdom: 10, charisma: 10) }
  let!(:vek)    { Npc.create!(name: "Vek", subrole: "marauder", location: tavern, dexterity: 12, strength: 12, constitution: 12, intelligence: 8, wisdom: 8, charisma: 6, current_hp: 20, max_hp: 20) }

  def make_combat_context(extra_chars: [])
    Harness::Scene::Assembler
    chars  = [ player, vek, *extra_chars ]
    snap   = Harness::Scene::Snapshot.new(location: tavern, present_characters: chars, present_corpses: [], present_items: [])
    active = Harness::Scene::Active.new(location: tavern, snapshot: snap, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
    active.start_combat!
    active.combat.add_combatant(player.id, side: "player_party")
    active.combat.add_combatant(vek.id,    side: "marauders")
    extra_chars.each { |c| active.combat.add_combatant(c.id, side: "marauders") }
    active.combat.initiative = [ player.id, vek.id, *extra_chars.map(&:id) ]
    ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 0)
    ctx.active_scene = active
    ctx
  end

  def stub_dice_outcome(result:, margin: "clear", critical: false)
    allow(::Harness::Dice).to receive(:check).and_return(
      ::Harness::Dice::Outcome.new(result: result, margin: margin, critical: critical)
    )
  end

  describe "validation" do
    it "errors when not in combat" do
      Harness::Scene::Assembler
      active = Harness::Scene::Active.new(location: tavern, snapshot: nil, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
      ctx = Harness::Turn::Context.new(player_location: tavern); ctx.active_scene = active
      out = described_class.new.call({ "actor_id" => player.id }, ctx)
      expect(out["error"]).to eq("not in combat")
    end

    it "errors when actor isn't a combatant" do
      ctx = make_combat_context
      out = described_class.new.call({ "actor_id" => 99_999 }, ctx)
      expect(out["error"]).to match(/not a combatant/)
    end

    it "errors when it isn't actor's turn" do
      ctx = make_combat_context
      out = described_class.new.call({ "actor_id" => vek.id }, ctx)
      expect(out["error"]).to match(/not actor_id=#{vek.id}'s turn/)
    end
  end

  describe "success" do
    it "moves player to scene parent and clears them from combat state" do
      ctx = make_combat_context
      ctx.active_scene.combat.engage!(player.id, vek.id)
      stub_dice_outcome(result: "success", margin: "clear")
      out = described_class.new.call({ "actor_id" => player.id }, ctx)
      expect(out["error"]).to be_nil
      expect(out["escaped"]).to be(true)
      expect(out["destination"]).to eq(city.id)
      expect(player.reload.location_id).to eq(city.id)
      state = ctx.active_scene.combat
      expect(state.combatant?(player.id)).to be(false)
      expect(state.engaged_with_of(vek.id)).to be_nil
    end

    it "sets scene_dirty when player escapes" do
      ctx = make_combat_context
      stub_dice_outcome(result: "success", margin: "narrow")
      described_class.new.call({ "actor_id" => player.id }, ctx)
      expect(ctx.scene_dirty).to be(true)
    end

    it "NPC escaping a top-level wilderness leaf gets location_id=nil" do
      forest = Location.create!(name: "Clearing", x: 50, y: 50, biome: "lowland")
      hp = Player.create!(name: "Wanderer", location: forest, dexterity: 10)
      ally = Npc.create!(name: "Bram", subrole: "fighter", location: forest, dexterity: 8, current_hp: 12, max_hp: 12)
      foe  = Npc.create!(name: "Foe",  subrole: "bandit", location: forest, dexterity: 8, current_hp: 8, max_hp: 8)
      Harness::Scene::Assembler
      snap   = Harness::Scene::Snapshot.new(location: forest, present_characters: [ hp, ally, foe ], present_corpses: [], present_items: [])
      active = Harness::Scene::Active.new(location: forest, snapshot: snap, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
      active.start_combat!
      active.combat.add_combatant(hp.id,   side: "player_party")
      active.combat.add_combatant(ally.id, side: "player_party")
      active.combat.add_combatant(foe.id,  side: "foes")
      active.combat.initiative = [ ally.id, hp.id, foe.id ]
      ctx = Harness::Turn::Context.new(player_location: forest); ctx.active_scene = active

      stub_dice_outcome(result: "success", margin: "clear")
      out = described_class.new.call({ "actor_id" => ally.id }, ctx)
      expect(out["escaped"]).to be(true)
      expect(ally.reload.location_id).to be_nil
    end

    it "Player escaping a wilderness leaf stays put + scene_dirty (no nil for player)" do
      forest = Location.create!(name: "Clearing", x: 50, y: 50, biome: "lowland")
      hp = Player.create!(name: "Wanderer", location: forest, dexterity: 14)
      foe = Npc.create!(name: "Foe", subrole: "bandit", location: forest, dexterity: 8, current_hp: 8, max_hp: 8)
      Harness::Scene::Assembler
      snap   = Harness::Scene::Snapshot.new(location: forest, present_characters: [ hp, foe ], present_corpses: [], present_items: [])
      active = Harness::Scene::Active.new(location: forest, snapshot: snap, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
      active.start_combat!
      active.combat.add_combatant(hp.id,  side: "player_party")
      active.combat.add_combatant(foe.id, side: "foes")
      active.combat.initiative = [ hp.id, foe.id ]
      ctx = Harness::Turn::Context.new(player_location: forest); ctx.active_scene = active

      stub_dice_outcome(result: "success", margin: "clear")
      described_class.new.call({ "actor_id" => hp.id }, ctx)
      expect(hp.reload.location_id).to eq(forest.id)
      expect(ctx.scene_dirty).to be(true)
    end
  end

  describe "failure" do
    it "engaged hostile gets a free hit through Resolve and slot closes" do
      ctx = make_combat_context
      ctx.active_scene.combat.engage!(player.id, vek.id)
      stub_dice_outcome(result: "failure", margin: "narrow")
      out = described_class.new.call({ "actor_id" => player.id }, ctx)
      expect(out["escaped"]).to be(false)
      expect(out["free_hit"]).to be_a(Hash)
      expect(out["slot_complete"]).to be(true)

      state = ctx.active_scene.combat
      expect(state.combatant?(player.id)).to be(true)  # still in combat
      expect(state.acted?(player.id)).to be(true)
      expect(state.moved?(player.id)).to be(true)
    end

    it "no engaged opponent → no free hit but slot still closes" do
      ctx = make_combat_context
      stub_dice_outcome(result: "failure", margin: "decisive")
      out = described_class.new.call({ "actor_id" => player.id }, ctx)
      expect(out["escaped"]).to be(false)
      expect(out["free_hit"]).to eq({ "no_opponent" => true })
      expect(out["slot_complete"]).to be(true)
    end

    it "free hit picks the engaged hostile's first close damage ability" do
      vek.update!(abilities: [
        { "name" => "Cleave", "stat" => "strength", "opposed_by" => "dexterity",
          "effect_kind" => "damage", "damage_dice" => "1d6", "range" => "close",
          "uses_remaining" => 2, "tags" => [ "martial" ], "requires_tags" => [] }
      ])
      ctx = make_combat_context
      ctx.active_scene.combat.engage!(player.id, vek.id)
      stub_dice_outcome(result: "failure", margin: "narrow")

      # Spy on Resolve invocation
      received = nil
      allow_any_instance_of(::Harness::Tools::Resolve).to receive(:call).and_wrap_original do |orig, args, context|
        received = args
        orig.call(args, context)
      end

      described_class.new.call({ "actor_id" => player.id }, ctx)
      expect(received["actor_id"]).to eq(vek.id)
      expect(received["target_id"]).to eq(player.id)
      expect(received["ability_name"]).to eq("Cleave")
    end

    it "free hit falls back to unarmed_strike when opponent has no melee damage abilities" do
      ctx = make_combat_context
      ctx.active_scene.combat.engage!(player.id, vek.id)
      stub_dice_outcome(result: "failure", margin: "narrow")

      received = nil
      allow_any_instance_of(::Harness::Tools::Resolve).to receive(:call).and_wrap_original do |orig, args, context|
        received = args
        orig.call(args, context)
      end

      described_class.new.call({ "actor_id" => player.id }, ctx)
      expect(received["ability_name"]).to eq("unarmed_strike")
    end
  end
end
