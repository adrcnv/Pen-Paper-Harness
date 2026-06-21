require "rails_helper"

RSpec.describe Harness::Scene::Initiative do
  let(:loc)     { Location.create!(name: "Tavern") }
  let(:logger)  { Logger.new(IO::NULL) }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 100) }
  let!(:player) { Player.create!(name: "Hero", location: loc) }

  def npc(name:, subrole: "barkeep", properties: {})
    Npc.create!(name: name, subrole: subrole, location: loc, current_hp: 5, max_hp: 5, properties: properties)
  end

  def active_with(present:, agendas: {}, internal_state: {}, cooldown: 0, pushes: {})
    snap = Struct.new(:location, :present_characters, :present_corpses, :present_items)
             .new(loc, present, [], [])
    a = Harness::Scene::Active.new(
      location: loc, snapshot: snap, narrations: [], internal_state: internal_state,
      agendas: agendas, extras: [], entered_at_game_time: 0,
      initiative_cooldown: cooldown, initiative_pushes: pushes
    )
    context.active_scene = a
    a
  end

  def transcript(tool_calls = [])
    t = Harness::Turn::Transcript.new(input: "look around", location_id: loc.id)
    t.record_tool_calls(tool_calls) if tool_calls.any?
    t
  end

  def run(active, t)
    described_class.run(context: context, active: active, transcript: t, logger: logger)
  end

  def names(t) = t.tool_calls.map { |tc| tc["name"] }

  it "no-ops when an NPC has neither an agenda nor an internal_state" do
    maren = npc(name: "Maren")
    a = active_with(present: [ maren ], agendas: {}, internal_state: {})
    t = transcript
    expect(run(a, t)).to be_nil
    expect(t.tool_calls).to be_empty
  end

  it "arms the cadence on the first eligible turn instead of firing immediately" do
    maren = npc(name: "Maren")
    a = active_with(present: [ maren ], agendas: { maren.id => "wants to warn the player" }, cooldown: nil)
    t = transcript
    expect(run(a, t)).to be_nil
    expect(t.tool_calls).to be_empty
    expect(a.initiative_cooldown).to eq(described_class::CADENCE - 1)
  end

  describe "ambient voicing (v2 — the firing fix)" do
    it "voices an NPC's internal_state as a beat when they have no agenda" do
      maren = npc(name: "Maren", subrole: "barkeep")
      a = active_with(present: [ maren ], agendas: {},
                      internal_state: { maren.id => "his back aches and the delivery is late" }, cooldown: 0)
      t = transcript
      expect(run(a, t)).to eq(maren)
      expect(names(t)).to include("propose_event")
      expect(names(t)).not_to include("start_combat")
      expect(a.initiative_pushes[maren.id]).to eq(1)
    end

    it "a no-agenda NPC NEVER escalates, even fight-capable and previously pushed" do
      bandit = npc(name: "Vek", subrole: "bandit")
      a = active_with(present: [ bandit ], agendas: {},
                      internal_state: { bandit.id => "watchful, sizing up the room" },
                      cooldown: 0, pushes: { bandit.id => 1 })
      t = transcript
      # already voiced once + no agenda → not re-picked, nothing fires, no combat
      expect(run(a, t)).to be_nil
      expect(names(t)).not_to include("start_combat")
      expect(context.active_scene.in_combat?).to be(false)
    end

    it "rotates to an un-voiced NPC rather than repeating one" do
      a_npc = npc(name: "Ada")
      b_npc = npc(name: "Bo")
      a = active_with(present: [ a_npc, b_npc ], agendas: {},
                      internal_state: { a_npc.id => "ada is tired", b_npc.id => "bo is restless" },
                      cooldown: 0, pushes: { a_npc.id => 1 })  # Ada already voiced
      t = transcript
      expect(run(a, t)).to eq(b_npc)  # picks the fresh one
      expect(a.initiative_pushes[b_npc.id]).to eq(1)
    end

    it "prefers a fresh agenda holder over an ambient NPC (stronger hook)" do
      ambient = npc(name: "Ada")
      agenda  = npc(name: "Bo")
      a = active_with(present: [ ambient, agenda ],
                      agendas: { agenda.id => "wants to hire the player for a job" },
                      internal_state: { ambient.id => "ada is tired" }, cooldown: 0)
      t = transcript
      expect(run(a, t)).to eq(agenda)
    end
  end

  it "fires a propose_event beat for a peaceful agenda NPC" do
    maren = npc(name: "Maren", subrole: "barkeep")
    a = active_with(present: [ maren ], agendas: { maren.id => "wants to warn the player about the docks" }, cooldown: 0)
    t = transcript
    expect(run(a, t)).to eq(maren)
    expect(names(t)).to include("propose_event")
    expect(names(t)).not_to include("start_combat")
    expect(a.initiative_cooldown).to eq(described_class::CADENCE)
    expect(a.initiative_pushes[maren.id]).to eq(1)
  end

  it "NEVER escalates a peaceful agenda NPC even on a repeat push (the tavern-keep guarantee)" do
    maren = npc(name: "Maren", subrole: "barkeep")
    a = active_with(present: [ maren ], agendas: { maren.id => "wants the tab settled" },
                    cooldown: 0, pushes: { maren.id => 1 })
    t = transcript
    run(a, t)
    expect(names(t)).to include("propose_event")
    expect(names(t)).not_to include("start_combat")
    expect(context.active_scene.in_combat?).to be(false)
  end

  it "escalates a fight-capable (martial subrole) agenda NPC to combat on the 2nd push" do
    bandit = npc(name: "Vek", subrole: "bandit")
    a = active_with(present: [ bandit ], agendas: { bandit.id => "means to rob the player" },
                    cooldown: 0, pushes: { bandit.id => 1 })
    t = transcript
    run(a, t)
    expect(names(t)).to include("start_combat")
    expect(context.active_scene.in_combat?).to be(true)
  end

  it "treats a seeded role_intent as fight-capable (the bar tough)" do
    tough = npc(name: "Rurik", subrole: "patron", properties: { "role_intent" => "spoiling for a fight" })
    a = active_with(present: [ tough ], agendas: { tough.id => "looking for an excuse to swing at the player" },
                    cooldown: 0, pushes: { tough.id => 1 })
    t = transcript
    run(a, t)
    expect(names(t)).to include("start_combat")
  end

  it "does NOT escalate a fight-capable agenda NPC on the FIRST push (only voices the beat)" do
    bandit = npc(name: "Vek", subrole: "bandit")
    a = active_with(present: [ bandit ], agendas: { bandit.id => "means to rob the player" }, cooldown: 0)
    t = transcript
    run(a, t)
    expect(names(t)).to include("propose_event")
    expect(names(t)).not_to include("start_combat")
  end

  it "resets push pressure and skips when the player engaged the NPC this turn" do
    maren = npc(name: "Maren")
    engaged = {
      "name" => "propose_event", "args" => {},
      "result" => { "participants" => [
        { "character_id" => maren.id,  "role" => "actor" },
        { "character_id" => player.id, "role" => "target" }
      ] }
    }
    a = active_with(present: [ maren ], agendas: { maren.id => "wants to warn the player" },
                    cooldown: 0, pushes: { maren.id => 1 })
    t = transcript([ engaged ])
    expect(run(a, t)).to be_nil
    expect(a.initiative_pushes[maren.id]).to eq(0)
    expect(t.tool_calls.size).to eq(1) # no new beat beyond the engagement already there
  end

  it "skips followers (they ride with the player, not initiative targets)" do
    ally = npc(name: "Bjorn", subrole: "fighter", properties: { "following_player" => true })
    a = active_with(present: [ ally ], agendas: { ally.id => "wants to chat" },
                    internal_state: { ally.id => "glad to be on the road" }, cooldown: 0)
    t = transcript
    expect(run(a, t)).to be_nil
    expect(t.tool_calls).to be_empty
  end
end
