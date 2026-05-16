require "rails_helper"

RSpec.describe Harness::Combat::Loop do
  let(:loc)    { Location.create!(name: "Tavern") }
  let!(:player) { Player.create!(name: "Mud", location: loc, current_hp: 20, max_hp: 20, dexterity: 14, strength: 12, constitution: 12, intelligence: 10, wisdom: 10, charisma: 10) }
  let!(:vek)    { Npc.create!(name: "Vek", subrole: "marauder", location: loc, current_hp: 18, max_hp: 18, dexterity: 12, strength: 14, constitution: 12, intelligence: 8, wisdom: 8, charisma: 6) }

  def make_combat_context(parent: nil)
    if parent
      loc.update!(parent: parent)
    end
    Harness::Scene::Assembler
    snap   = Harness::Scene::Snapshot.new(location: loc, present_characters: [ player, vek ], present_corpses: [], present_items: [])
    active = Harness::Scene::Active.new(location: loc, snapshot: snap, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
    active.start_combat!
    active.combat.add_combatant(player.id, side: "player_party")
    active.combat.add_combatant(vek.id,    side: "marauders")
    active.combat.initiative = [ player.id, vek.id ]
    ctx = Harness::Turn::Context.new(player_location: loc, game_time: 0)
    ctx.active_scene = active
    ctx
  end

  describe "no-adapter test path" do
    it "auto-end_turns every slot and hits MAX_ROUNDS (stalemate)" do
      ctx = make_combat_context
      result = described_class.new(context: ctx, adapter: nil).run
      expect(result.end_reason).to eq(:round_cap_reached)
      expect(result.rounds).to eq(described_class::MAX_ROUNDS)
      expect(ctx.active_scene.in_combat?).to be(false)
      expect(ctx.scene_dirty).to be(true)
    end
  end

  describe "termination integration" do
    it "ends with :victory pre-flight when the only enemy is already dead" do
      ctx = make_combat_context
      vek.update!(current_hp: 0)  # already dead — caught pre-flight before any round runs
      result = described_class.new(context: ctx, adapter: nil).run
      expect(result.end_reason).to eq(:victory)
      expect(result.rounds).to eq(0)
    end

    it "ends with :player_died pre-flight when player is already at 0 HP" do
      ctx = make_combat_context
      player.update!(current_hp: 0)
      result = described_class.new(context: ctx, adapter: nil).run
      expect(result.end_reason).to eq(:player_died)
      expect(result.rounds).to eq(0)
    end

    it "ends with :player_fled pre-flight and runs PlayerFledResolution when player leaves scene" do
      parent = Location.create!(name: "City")
      ctx = make_combat_context(parent: parent)
      player.update!(location_id: parent.id)
      allow(Harness::Combat::PlayerFledResolution).to receive(:run).and_return({ "summary_prose" => "wrap-up", "outcomes" => [] })
      result = described_class.new(context: ctx, adapter: nil).run
      expect(result.end_reason).to eq(:player_fled)
      expect(Harness::Combat::PlayerFledResolution).to have_received(:run)
      expect(result.player_fled_resolution["summary_prose"]).to eq("wrap-up")
    end

    it "clears combat state and sets scene_dirty on termination" do
      ctx = make_combat_context
      vek.update!(current_hp: 0)
      described_class.new(context: ctx, adapter: nil).run
      expect(ctx.active_scene.in_combat?).to be(false)
      expect(ctx.scene_dirty).to be(true)
    end
  end

  describe "round summaries" do
    it "produces one summary per round with actions + narration text (test path stalemate)" do
      ctx = make_combat_context
      stub_const("Harness::Combat::Loop::MAX_ROUNDS", 2)
      result = described_class.new(context: ctx, adapter: nil).run
      expect(result.end_reason).to eq(:round_cap_reached)
      expect(result.round_summaries.size).to eq(2)
      summary = result.round_summaries.first
      expect(summary["round"]).to eq(1)
      expect(summary["actions"]).to be_an(Array)
      expect(summary["actions"].any? { |a| a["actor_name"] == "Mud" }).to be(true)
      expect(summary["narration"]).to be_a(String)
    end
  end

  describe "yield at fresh player slot (production: adapter present)" do
    it "yields immediately when no player tokens are spent" do
      ctx = make_combat_context
      adapter = double("adapter")
      result = described_class.new(context: ctx, adapter: adapter).run
      expect(result.end_reason).to eq(:yielded)
      expect(result.rounds).to eq(0)
      expect(ctx.active_scene.in_combat?).to be(true)
      expect(ctx.scene_dirty).to be(false)
    end

    it "advances past player slot when the reasoning loop marked tokens, then yields at next player slot" do
      ctx = make_combat_context
      state = ctx.active_scene.combat
      state.mark_acted!(player.id)  # simulates a player resolve in the reasoning loop

      # Stub NpcTurn so we don't need a real LLM. It just marks tokens.
      allow(Harness::Combat::NpcTurn).to receive(:run) do
        state.mark_acted!(vek.id)
        state.mark_moved!(vek.id)
      end

      adapter = double("adapter")
      result = described_class.new(context: ctx, adapter: adapter).run
      expect(result.end_reason).to eq(:yielded)
      expect(result.rounds).to eq(1)  # round 1 completed; yield at round 2's player slot
      expect(ctx.active_scene.in_combat?).to be(true)
    end
  end
end
