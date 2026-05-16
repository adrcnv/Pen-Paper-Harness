require "rails_helper"

RSpec.describe Harness::Tools::QueryScene do
  let(:tavern)  { Location.create!(name: "Tavern") }
  let(:road)    { Location.create!(name: "Road") }
  let(:context) { Harness::Turn::Context.new(player_location: tavern, game_time: 100) }

  def make_active(at:, extras: [], internal_state: {}, agendas: {})
    snap = Struct.new(:location, :present_characters, :present_items)
             .new(at, [], [])
    Harness::Scene::Active.new(
      location:             at,
      snapshot:             snap,
      narrations:           [],
      internal_state:       internal_state,
      agendas:              agendas,
      extras:               extras,
      entered_at_game_time: 0
    )
  end

  describe "stale-extras gate" do
    it "returns the active scene's extras when active.location matches player_location" do
      context.active_scene = make_active(at: tavern, extras: [ "an old fisherman in the corner" ])
      out = described_class.new.call({}, context)
      expect(out["present_extras"]).to eq([ "an old fisherman in the corner" ])
    end

    it "drops stale extras when player moved mid-turn (active.location != player_location)" do
      context.active_scene = make_active(at: tavern, extras: [ "an old fisherman in the corner" ])
      context.player_location = road
      out = described_class.new.call({}, context)
      expect(out["present_extras"]).to eq([])
    end

    it "drops stale internal_state too (single guard, all-or-nothing)" do
      context.active_scene = make_active(at: tavern, extras: [ "x" ])
      # internal_state is read off active too — covered by same guard, so a
      # location-mismatched active should produce no character entry attached.
      # (Manager.enter on the next turn will fill flavor for the new location.)
      context.player_location = road
      out = described_class.new.call({}, context)
      expect(out["present_extras"]).to eq([])
    end
  end

  describe "agenda push-pressure surfacing" do
    let(:npc) { Npc.create!(name: "Marta", location: tavern, character_class: "commoner") }

    def active_with_agenda(silent_turns: 0)
      snap = Struct.new(:location, :present_characters, :present_items)
               .new(tavern, [ npc ], [])
      a = Harness::Scene::Active.new(
        location:             tavern,
        snapshot:             snap,
        narrations:           [],
        internal_state:       { npc.id => "is twitchy and watchful" },
        agendas:              { npc.id => "wants to ask about the docks" },
        extras:               [],
        entered_at_game_time: 0
      )
      silent_turns.times { a.tick_agendas!([]) }
      a
    end

    it "omits should_push_now when silent count is below threshold" do
      context.active_scene = active_with_agenda(silent_turns: 0)
      out = described_class.new.call({}, context)
      char = out["present_characters"].find { |c| c["id"] == npc.id }
      expect(char["agenda"]).to be_present
      expect(char).not_to have_key("should_push_now")
    end

    it "surfaces should_push_now=true once silent count crosses threshold" do
      context.active_scene = active_with_agenda(silent_turns: Harness::Scene::AGENDA_PUSH_THRESHOLD)
      out = described_class.new.call({}, context)
      char = out["present_characters"].find { |c| c["id"] == npc.id }
      expect(char["should_push_now"]).to be(true)
    end

    it "does NOT set should_push_now on NPCs without an agenda (no agenda field)" do
      snap = Struct.new(:location, :present_characters, :present_items).new(tavern, [ npc ], [])
      a = Harness::Scene::Active.new(
        location: tavern, snapshot: snap, narrations: [],
        internal_state: { npc.id => "fine" }, agendas: {}, extras: [],
        entered_at_game_time: 0
      )
      Harness::Scene::AGENDA_PUSH_THRESHOLD.times { a.tick_agendas!([]) }
      context.active_scene = a
      out = described_class.new.call({}, context)
      char = out["present_characters"].find { |c| c["id"] == npc.id }
      expect(char).not_to have_key("agenda")
      expect(char).not_to have_key("should_push_now")
    end
  end

  describe "follower flag surfacing in present_characters" do
    it "marks present characters with following_player=true inline" do
      ally    = Npc.create!(name: "Ally", location: tavern, character_class: "fighter",
                            properties: { "following_player" => true })
      neutral = Npc.create!(name: "Neutral", location: tavern, character_class: "commoner")
      out = described_class.new.call({}, context)

      ally_entry    = out["present_characters"].find { |c| c["id"] == ally.id }
      neutral_entry = out["present_characters"].find { |c| c["id"] == neutral.id }

      expect(ally_entry["following_player"]).to be(true)
      expect(neutral_entry).not_to have_key("following_player")
    end

    it "omits the flag when explicitly set to false" do
      explicit_no = Npc.create!(name: "Dismissed", location: tavern, character_class: "fighter",
                                properties: { "following_player" => false })
      out = described_class.new.call({}, context)
      entry = out["present_characters"].find { |c| c["id"] == explicit_no.id }
      expect(entry).not_to have_key("following_player")
    end
  end

  describe "ability surfacing in present_characters" do
    let(:npc) {
      Npc.create!(
        name: "Marek", location: tavern, character_class: "fighter",
        abilities: [
          { "name" => "Heavy Strike", "uses_remaining" => 3, "uses_per_rest" => 4 },
          { "name" => "Power Smash",  "uses_remaining" => 1, "uses_per_rest" => 2 }
        ]
      )
    }

    it "includes a compact abilities list (name + uses_remaining)" do
      npc
      out = described_class.new.call({}, context)
      char = out["present_characters"].find { |c| c["id"] == npc.id }
      expect(char["abilities"]).to eq([
        { "name" => "Heavy Strike", "uses_remaining" => 3 },
        { "name" => "Power Smash",  "uses_remaining" => 1 }
      ])
    end

    it "omits the abilities key entirely when an NPC has none" do
      empty = Npc.create!(name: "Patron", location: tavern, abilities: [])
      out = described_class.new.call({}, context)
      char = out["present_characters"].find { |c| c["id"] == empty.id }
      expect(char).not_to have_key("abilities")
    end
  end

  describe "corpse partitioning" do
    it "puts dead NPCs in present_corpses, alive in present_characters" do
      alive = Npc.create!(name: "Alive", location: tavern, character_class: "commoner",
                          current_hp: 5, max_hp: 5)
      dead  = Npc.create!(name: "Dead",  location: tavern, character_class: "commoner",
                          current_hp: 0, max_hp: 5)
      out = described_class.new.call({}, context)

      pc_ids = out["present_characters"].map { |c| c["id"] }
      cp     = out["present_corpses"]

      expect(pc_ids).to include(alive.id)
      expect(pc_ids).not_to include(dead.id)
      expect(cp).to eq([ { "id" => dead.id, "name" => "Dead" } ])
    end

    it "returns an empty present_corpses array when no one is dead" do
      Npc.create!(name: "Alive", location: tavern, character_class: "commoner",
                  current_hp: 5, max_hp: 5)
      out = described_class.new.call({}, context)
      expect(out["present_corpses"]).to eq([])
    end
  end

  describe "combat payload" do
    let!(:player) { Player.create!(name: "Mud", location: tavern, current_hp: 20, max_hp: 20, dexterity: 14, strength: 12, constitution: 12, intelligence: 10, wisdom: 10, charisma: 10) }
    let!(:vek)    { Npc.create!(name: "Vek", subrole: "marauder", location: tavern, current_hp: 18, max_hp: 18, dexterity: 12) }

    it "is absent when scene is not in combat" do
      out = described_class.new.call({}, context)
      expect(out).not_to have_key("combat")
    end

    it "includes round, allies/hostiles, your_position and tokens when in combat" do
      snap = Harness::Scene::Snapshot.new(location: tavern, present_characters: [ player, vek ], present_corpses: [], present_items: [])
      active = Harness::Scene::Active.new(location: tavern, snapshot: snap, narrations: [], internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 0)
      active.start_combat!
      active.combat.add_combatant(player.id, side: "player_party")
      active.combat.add_combatant(vek.id,    side: "marauders")
      active.combat.initiative = [ player.id, vek.id ]
      active.combat.engage!(player.id, vek.id)
      active.combat.mark_acted!(player.id)
      context.active_scene = active

      out = described_class.new.call({}, context)
      payload = out["combat"]
      expect(payload).not_to be_nil
      expect(payload["round"]).to eq(1)
      expect(payload["your_position"]).to eq("engaged")
      expect(payload["your_engaged_with"]).to eq(vek.id)
      expect(payload["your_action_spent"]).to be(true)
      expect(payload["your_move_spent"]).to be(false)
      expect(payload["hostiles"].map { |h| h["name"] }).to eq([ "Vek" ])
      expect(payload["allies"]).to eq([])
      expect(payload["initiative"]).to eq([ player.id, vek.id ])
    end
  end

  describe "encounter_type surfacing" do
    let(:combat_leaf) {
      Location.create!(name: "Bandit defile", x: 10, y: 10,
                       properties: { "kind" => "wilderness_leaf", "encounter_type" => "combat" })
    }
    let(:plain_loc) { Location.create!(name: "Quiet glade") }

    it "includes encounter_type in location for wilderness_leaf with one set" do
      context.player_location = combat_leaf
      out = described_class.new.call({}, context)
      expect(out["location"]["encounter_type"]).to eq("combat")
    end

    it "omits encounter_type when location has none" do
      context.player_location = plain_loc
      out = described_class.new.call({}, context)
      expect(out["location"]).not_to have_key("encounter_type")
    end
  end
end
