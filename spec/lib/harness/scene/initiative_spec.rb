require "rails_helper"

RSpec.describe Harness::Scene::Initiative do
  let(:loc)     { Location.create!(name: "Tavern") }
  let(:logger)  { Logger.new(IO::NULL) }
  let!(:player) { Player.create!(name: "Hero", location: loc) }

  # Default consumer response: nobody acts. Individual tests override `llm`.
  let(:llm)     { stub_llm(emit(actor: nil)) }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 100, llm_nuance: llm) }

  def stub_llm(body)
    Class.new { define_method(:complete) { |system:, user:| body } }.new
  end

  def emit(actor:, kind: "engage", beat: "leans in toward the player and says a few low words", target: nil)
    h = { "actor" => actor, "kind" => kind, "beat" => (actor.nil? ? "" : beat) }
    h["target"] = target if target
    h.to_json
  end

  def npc(name:, subrole: "barkeep", properties: {})
    Npc.create!(name: name, subrole: subrole, location: loc, current_hp: 5, max_hp: 5, properties: properties)
  end

  # cooldown: 0 means past the arrival-settle (the common test case). Pass nil
  # to exercise the settle. last_initiator excludes the previous turn's actor.
  def active_with(present:, agendas: {}, internal_state: {}, cooldown: 0, last_initiator: nil)
    snap = Struct.new(:location, :present_characters, :present_corpses, :present_items)
             .new(loc, present, [], [])
    a = Harness::Scene::Active.new(
      location: loc, snapshot: snap, narrations: [], internal_state: internal_state,
      agendas: agendas, extras: [], entered_at_game_time: 0,
      initiative_cooldown: cooldown, last_initiator: last_initiator
    )
    context.active_scene = a
    a
  end

  def transcript(tool_calls = [])
    t = Harness::Turn::Transcript.new(input: "look around", location_id: loc.id)
    t.record_tool_calls(tool_calls) if tool_calls.any?
    t
  end

  def run(active, t, narration: "The room is quiet.")
    described_class.run(context: context, active: active, transcript: t, narration: narration, logger: logger)
  end

  def names(t) = t.tool_calls.map { |tc| tc["name"] }

  it "settles on the arrival turn (cooldown nil) without firing" do
    maren = npc(name: "Maren")
    a = active_with(present: [ maren ], agendas: { maren.id => "wants to warn the player" }, cooldown: nil)
    t = transcript
    expect(run(a, t)).to be_nil
    expect(t.tool_calls).to be_empty
    expect(a.initiative_cooldown).to eq(0) # armed; fires from next turn
  end

  it "leads a pronoun-opening beat with the actor's name (dangling-antecedent guard), leaving name-led beats alone" do
    gerd = npc(name: "Gerd Vegirsson", subrole: "guard")
    a = active_with(present: [ gerd ], agendas: { gerd.id => "wants the stranger gone" })
    context.llm_nuance = stub_llm(emit(actor: "Gerd Vegirsson", beat: "She steps forward, hand resting on the pommel of her sword."))
    result = run(a, transcript)
    expect(result[:beat]).to eq("Gerd Vegirsson — She steps forward, hand resting on the pommel of her sword.")

    b = active_with(present: [ gerd ], agendas: { gerd.id => "wants the stranger gone" })
    context.llm_nuance = stub_llm(emit(actor: "Gerd Vegirsson", beat: "Gerd steps forward with a glare."))
    result = run(b, transcript)
    expect(result[:beat]).to eq("Gerd steps forward with a glare.")
  end

  it "fires the beat the consumer picks, STAGES it (no Event row), and records the initiator" do
    maren = npc(name: "Maren", subrole: "barkeep")
    a = active_with(present: [ maren ], agendas: { maren.id => "wants to warn the player about the docks" })
    context.llm_nuance = stub_llm(emit(actor: "Maren", beat: "Maren sets down a mug and says the docks aren't safe after dark."))
    t = transcript
    result = nil
    # The beat renders (return value) and is recorded for the turn log, but it
    # must NOT persist as an Event — initiative improv self-canonizing into the
    # log is the pollution this fixes.
    expect { result = run(a, t) }.not_to change(Event, :count)
    expect(result[:npc]).to eq(maren)
    expect(result[:beat]).to match(/docks/)
    rec = t.tool_calls.find { |tc| tc["name"] == "propose_event" }
    expect(rec).to be_present
    expect(rec.dig("result", "staged")).to be(true)
    expect(a.last_initiator).to eq(maren.id)
  end

  it "appends nothing when the consumer picks nobody (actor null)" do
    maren = npc(name: "Maren")
    a = active_with(present: [ maren ], agendas: { maren.id => "wants to warn the player" })
    # default llm returns actor: nil
    t = transcript
    expect(run(a, t)).to be_nil
    expect(names(t)).not_to include("propose_event")
  end

  it "aims a beat at ANOTHER present character when target names them (NPC-to-NPC)" do
    maren = npc(name: "Maren", subrole: "barkeep")
    korr  = npc(name: "Korr", subrole: "patron")
    a = active_with(present: [ maren, korr ], agendas: { maren.id => "wants to needle Korr about his tab" })
    context.llm_nuance = stub_llm(emit(actor: "Maren", target: "Korr",
      beat: "Maren turns to Korr and asks, loud enough for the room, when he means to settle his tab."))
    t = transcript
    run(a, t)
    rec = t.tool_calls.find { |tc| tc["name"] == "propose_event" }
    targeted = rec.dig("args", "participants").find { |p| p["role"] == "target" }
    expect(targeted["character_id"]).to eq(korr.id)         # aimed at Korr, not the player
    expect(rec.dig("args", "details")).to match(/toward Korr/)
  end

  it "tags a watch-kind beat's player participant as a witness, not a target" do
    korr = npc(name: "Korr", subrole: "patron")
    a = active_with(present: [ korr ], agendas: { korr.id => "distrusts the stranger" })
    context.llm_nuance = stub_llm(emit(actor: "Korr", kind: "watch", beat: "Korr watches the newcomer over the rim of his cup."))
    t = transcript
    run(a, t)
    ev = t.tool_calls.find { |tc| tc["name"] == "propose_event" }
    roles = ev.dig("args", "participants").map { |p| p["role"] }
    expect(roles).to include("witness")
    expect(roles).not_to include("target")
  end

  it "ignores an invalid actor name the consumer invents" do
    maren = npc(name: "Maren")
    a = active_with(present: [ maren ], agendas: { maren.id => "wants to warn the player" })
    context.llm_nuance = stub_llm(emit(actor: "Ghost"))
    t = transcript
    expect(run(a, t)).to be_nil
    expect(names(t)).not_to include("propose_event")
  end

  it "skips followers (they ride with the player, not initiative targets)" do
    ally = npc(name: "Bjorn", subrole: "fighter", properties: { "following_player" => true })
    a = active_with(present: [ ally ], agendas: { ally.id => "wants to chat" })
    context.llm_nuance = stub_llm(emit(actor: "Bjorn"))
    t = transcript
    expect(run(a, t)).to be_nil # no eligible candidates → consumer not even consulted
    expect(t.tool_calls).to be_empty
  end

  it "prefers a NOT-engaged NPC over the one the player just engaged" do
    maren = npc(name: "Maren")
    korr  = npc(name: "Korr", subrole: "patron")
    engaged = {
      "name" => "propose_event", "args" => {},
      "result" => { "participants" => [
        { "character_id" => maren.id,  "role" => "actor" },
        { "character_id" => player.id, "role" => "target" }
      ] }
    }
    a = active_with(present: [ maren, korr ],
                    agendas: { maren.id => "wants to warn the player", korr.id => "sizes up the newcomer" })
    context.llm_nuance = stub_llm(emit(actor: "Korr"))
    t = transcript([ engaged ])
    result = run(a, t)
    expect(result[:npc]).to eq(korr) # Maren was engaged → Korr is preferred
  end

  it "falls back to the engaged NPC in a one-on-one (else initiative can never fire in a two-hander)" do
    maren = npc(name: "Maren")
    engaged = {
      "name" => "propose_event", "args" => {},
      "result" => { "participants" => [
        { "character_id" => maren.id,  "role" => "actor" },
        { "character_id" => player.id, "role" => "target" }
      ] }
    }
    a = active_with(present: [ maren ], agendas: { maren.id => "wants to warn the player" })
    context.llm_nuance = stub_llm(emit(actor: "Maren", beat: "Maren leans in: there's something you should know before you go."))
    t = transcript([ engaged ])
    result = run(a, t)
    expect(result[:npc]).to eq(maren) # only NPC present — engaged or not, she can act
  end

  it "excludes the previous turn's initiator so the room rotates" do
    ada = npc(name: "Ada")
    bo  = npc(name: "Bo")
    a = active_with(present: [ ada, bo ],
                    agendas: { ada.id => "wants to talk", bo.id => "wants to warn the player" },
                    last_initiator: ada.id)
    context.llm_nuance = stub_llm(emit(actor: "Bo"))
    t = transcript
    result = run(a, t)
    expect(result[:npc]).to eq(bo)
  end

  it "no-ops with no present NPCs" do
    a = active_with(present: [])
    t = transcript
    expect(run(a, t)).to be_nil
    expect(t.tool_calls).to be_empty
  end

  it "no-ops while in combat" do
    bandit = npc(name: "Vek", subrole: "bandit")
    a = active_with(present: [ bandit ], agendas: { bandit.id => "means to rob the player" })
    a.start_combat!
    context.llm_nuance = stub_llm(emit(actor: "Vek"))
    t = transcript
    expect(run(a, t)).to be_nil
    expect(names(t)).not_to include("propose_event")
  end
end
