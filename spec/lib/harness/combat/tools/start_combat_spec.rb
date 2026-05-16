require "rails_helper"

RSpec.describe Harness::Combat::Tools::StartCombat do
  let(:city)   { Location.create!(name: "Saltmere") }
  let(:tavern) { Location.create!(name: "Tavern", parent: city) }
  let!(:player) { Player.create!(name: "Mud", location: tavern, dexterity: 14) }
  let!(:vek)    { Npc.create!(name: "Vek", subrole: "marauder", location: tavern, dexterity: 16, current_hp: 20, max_hp: 20) }
  let!(:rask)   { Npc.create!(name: "Rask", subrole: "marauder", location: tavern, dexterity: 8, current_hp: 18, max_hp: 18) }

  def make_context(extras: [], present_characters: nil, llm: nil)
    Harness::Scene::Assembler # force-load so Snapshot is defined
    chars = present_characters || [ player, vek, rask ]
    snapshot = Harness::Scene::Snapshot.new(
      location: tavern, present_characters: chars, present_corpses: [], present_items: []
    )
    active = Harness::Scene::Active.new(
      location: tavern, snapshot: snapshot, narrations: [], internal_state: {}, agendas: {},
      extras: extras, entered_at_game_time: 100
    )
    Harness::Turn::Context.new(player_location: tavern, game_time: 100, llm_client: llm).tap { |c|
      c.active_scene = active
    }
  end

  let(:two_sides) {
    [
      { "name" => "player_party", "members" => [ player.id ] },
      { "name" => "marauders",    "members" => [ vek.id, rask.id ] }
    ]
  }

  describe "happy path with no bystanders" do
    it "starts combat, rolls initiative for all combatants, commits a personal-scope event" do
      ctx = make_context
      out = described_class.new.call({ "sides" => two_sides, "inciting_beat" => "Mud drew steel on Vek" }, ctx)
      expect(out["error"]).to be_nil
      expect(out["ok"]).to be(true)
      expect(out["round"]).to eq(1)
      expect(out["initiative"]).to match_array([ player.id, vek.id, rask.id ])
      expect(out["current_actor_id"]).to eq(out["initiative"].first)
      expect(out["deliberations"]).to eq([])
      expect(out["evicted_extras"]).to eq(0)

      expect(ctx.active_scene.in_combat?).to be(true)
      st = ctx.active_scene.combat
      expect(st.combatant?(player.id)).to be(true)
      expect(st.combatant?(vek.id)).to be(true)
      expect(st.side_of(player.id)).to eq("player_party")
      expect(st.side_of(vek.id)).to eq("marauders")
      expect(st.position_of(player.id)).to eq("near")

      ev = Event.find(out["event_id"])
      expect(ev.scope).to eq("personal")
      expect(ev.location_id).to eq(tavern.id)
      expect(ev.participants.map(&:id)).to match_array([ player.id, vek.id, rask.id ])
    end
  end

  describe "extras eviction" do
    it "evicts extras silently with no LLM call and clears scene.extras" do
      llm = StubLLM.new { raise "should not be called for extras" }
      ctx = make_context(extras: [ "an old fisherman in the corner", "a knitting woman by the fire" ], llm: llm)
      out = described_class.new.call({ "sides" => two_sides, "inciting_beat" => "Mud drew steel" }, ctx)
      expect(out["evicted_extras"]).to eq(2)
      expect(ctx.active_scene.extras).to eq([])
      expect(ctx.active_scene.combat.evicted_extras).to eq([ "an old fisherman in the corner", "a knitting woman by the fire" ])
      expect(llm.user_calls).to be_empty
    end
  end

  describe "bystander deliberation" do
    let!(:barkeep) { Npc.create!(name: "Maren", subrole: "barkeep", location: tavern, dexterity: 12, current_hp: 14, max_hp: 14, properties: { "personality" => "cautious" }) }

    it "calls deliberation once per uncommitted real character" do
      llm = StubLLM.new { '{"decision": "watch", "reason": "frozen behind the bar"}' }
      ctx = make_context(present_characters: [ player, vek, rask, barkeep ], llm: llm)
      out = described_class.new.call({ "sides" => two_sides, "inciting_beat" => "Mud drew steel" }, ctx)
      expect(llm.user_calls.size).to eq(1)
      expect(out["deliberations"].size).to eq(1)
      expect(out["deliberations"].first["character_id"]).to eq(barkeep.id)
      expect(out["deliberations"].first["decision"]).to eq("watch")

      st = ctx.active_scene.combat
      expect(st.watcher?(barkeep.id)).to be(true)
      expect(st.combatant?(barkeep.id)).to be(false)
    end

    it "join_player_side adds bystander to player's side and rolls them into initiative" do
      llm = StubLLM.new { '{"decision": "join_player_side", "reason": "the bouncer steps in"}' }
      ctx = make_context(present_characters: [ player, vek, rask, barkeep ], llm: llm)
      out = described_class.new.call({ "sides" => two_sides, "inciting_beat" => "Mud drew steel" }, ctx)
      expect(out["sides"].find { |s| s["name"] == "player_party" }["members"]).to include(barkeep.id)
      expect(ctx.active_scene.combat.side_of(barkeep.id)).to eq("player_party")
      expect(out["initiative"]).to include(barkeep.id)
    end

    it "join_enemy_side adds bystander to the largest non-player side" do
      llm = StubLLM.new { '{"decision": "join_enemy_side", "reason": "owes Vek a debt"}' }
      ctx = make_context(present_characters: [ player, vek, rask, barkeep ], llm: llm)
      out = described_class.new.call({ "sides" => two_sides, "inciting_beat" => "Mud drew steel" }, ctx)
      expect(ctx.active_scene.combat.side_of(barkeep.id)).to eq("marauders")
    end

    it "flee sets bystander location_id to scene parent and removes them from snapshot" do
      llm = StubLLM.new { '{"decision": "flee", "reason": "ran out the back door"}' }
      ctx = make_context(present_characters: [ player, vek, rask, barkeep ], llm: llm)
      described_class.new.call({ "sides" => two_sides, "inciting_beat" => "Mud drew steel" }, ctx)
      expect(barkeep.reload.location_id).to eq(city.id)
      expect(ctx.active_scene.combat.evicted_character_ids).to include(barkeep.id)
      expect(ctx.active_scene.snapshot.present_characters.map(&:id)).not_to include(barkeep.id)
    end

    it "flee sets location_id to nil at top-level wilderness leaf (no parent)" do
      wilderness = Location.create!(name: "Forest Clearing", x: 100, y: 100, biome: "lowland")
      forest_npc = Npc.create!(name: "Bandit", subrole: "bandit", location: wilderness, dexterity: 10, current_hp: 10, max_hp: 10)
      far_player = Player.create!(name: "Wanderer", location: wilderness, dexterity: 12)
      foe = Npc.create!(name: "Enemy", subrole: "bandit", location: wilderness, dexterity: 8, current_hp: 8, max_hp: 8)
      Player.where.not(id: far_player.id).destroy_all # ensure Player.first picks our wilderness one
      Harness::Scene::Assembler
      snap = Harness::Scene::Snapshot.new(location: wilderness, present_characters: [ far_player, foe, forest_npc ], present_corpses: [], present_items: [])
      active = Harness::Scene::Active.new(location: wilderness, snapshot: snap, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
      llm = StubLLM.new { '{"decision": "flee", "reason": "into the trees"}' }
      ctx = Harness::Turn::Context.new(player_location: wilderness, game_time: 100, llm_client: llm).tap { |c| c.active_scene = active }
      sides = [ { "name" => "player", "members" => [ far_player.id ] }, { "name" => "foes", "members" => [ foe.id ] } ]
      described_class.new.call({ "sides" => sides, "inciting_beat" => "ambush" }, ctx)
      expect(forest_npc.reload.location_id).to be_nil
    end
  end

  describe "follower auto-include" do
    let!(:follower) { Npc.create!(name: "Bram", subrole: "fighter", location: tavern, dexterity: 13, current_hp: 16, max_hp: 16, properties: { "following_player" => true }) }

    it "adds player's followers to player's side without deliberation" do
      llm = StubLLM.new { raise "follower should not need deliberation" }
      ctx = make_context(present_characters: [ player, vek, rask, follower ], llm: llm)
      out = described_class.new.call({ "sides" => two_sides, "inciting_beat" => "Mud drew steel" }, ctx)
      expect(out["followers_added"]).to eq([ follower.id ])
      expect(out["sides"].find { |s| s["name"] == "player_party" }["members"]).to include(follower.id)
      expect(ctx.active_scene.combat.side_of(follower.id)).to eq("player_party")
    end

    it "leaves the follower alone if already listed on player's side explicitly" do
      sides = [
        { "name" => "player_party", "members" => [ player.id, follower.id ] },
        { "name" => "marauders",    "members" => [ vek.id, rask.id ] }
      ]
      ctx = make_context(present_characters: [ player, vek, rask, follower ])
      out = described_class.new.call({ "sides" => sides, "inciting_beat" => "Mud drew steel" }, ctx)
      expect(out["followers_added"]).to eq([])
      expect(out["sides"].find { |s| s["name"] == "player_party" }["members"]).to include(follower.id)
    end
  end

  describe "validation" do
    it "errors on a single side" do
      ctx = make_context
      out = described_class.new.call({ "sides" => [ { "name" => "solo", "members" => [ player.id ] } ], "inciting_beat" => "x" }, ctx)
      expect(out["error"]).to match(/at least 2 sides/)
    end

    it "errors on character on multiple sides" do
      sides = [
        { "name" => "a", "members" => [ player.id, vek.id ] },
        { "name" => "b", "members" => [ vek.id, rask.id ] }
      ]
      ctx = make_context
      out = described_class.new.call({ "sides" => sides, "inciting_beat" => "x" }, ctx)
      expect(out["error"]).to match(/more than one side/)
    end

    it "errors when the player is not on any side" do
      sides = [
        { "name" => "a", "members" => [ vek.id ] },
        { "name" => "b", "members" => [ rask.id ] }
      ]
      ctx = make_context
      out = described_class.new.call({ "sides" => sides, "inciting_beat" => "x" }, ctx)
      expect(out["error"]).to match(/exactly one side/)
    end

    it "errors when a side member isn't present in the scene and surfaces the valid id set" do
      stranger = Npc.create!(name: "Stranger", subrole: "bandit", location: Location.create!(name: "Elsewhere"), dexterity: 10, current_hp: 10, max_hp: 10)
      sides = [
        { "name" => "a", "members" => [ player.id ] },
        { "name" => "b", "members" => [ stranger.id ] }
      ]
      ctx = make_context
      out = described_class.new.call({ "sides" => sides, "inciting_beat" => "x" }, ctx)
      expect(out["error"]).to match(/not present in the scene/)
      expect(out["error"]).to match(/valid ids in this scene/)
      # The valid set should include the player and Vek (the only present_character),
      # and exclude the stranger.
      expect(out["error"]).to include(player.id.to_s)
      expect(out["error"]).to include(vek.id.to_s)
      expect(out["error"]).not_to include("[#{stranger.id}]")
    end

    it "errors when called while already in combat" do
      ctx = make_context
      ctx.active_scene.start_combat!
      out = described_class.new.call({ "sides" => two_sides, "inciting_beat" => "x" }, ctx)
      expect(out["error"]).to eq("already in combat")
    end

    it "errors on empty inciting_beat" do
      ctx = make_context
      out = described_class.new.call({ "sides" => two_sides, "inciting_beat" => "" }, ctx)
      expect(out["error"]).to match(/inciting_beat/)
    end
  end
end
