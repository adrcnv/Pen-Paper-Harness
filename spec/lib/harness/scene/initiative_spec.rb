require "rails_helper"

RSpec.describe Harness::Scene::Initiative do
  let(:loc)     { Location.create!(name: "Tavern") }
  let(:logger)  { Logger.new(IO::NULL) }
  let!(:player) { Player.create!(name: "Hero", location: loc) }

  # Default consumer response: nobody acts. Individual tests override `llm`.
  let(:llm)     { stub_llm(selector: { "actor" => nil, "cause" => "" }) }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 100, llm_nuance: llm) }

  # v4: the initiative pass is a SELECTOR; the chosen NPC then speaks through
  # the conversation runner's full voicing (+ reflection + taking-stock).
  # The stub serves all four surfaces by prompt sniffing.
  def stub_llm(selector:, line: nil, speak: true)
    Class.new do
      define_method(:complete) do |system:, user:, schema: nil|
        full = "#{system}\n#{user}"
        if full.include?("TAKING STOCK")
          { "assessment" => "holds", "disposition" => "hold", "mood" => nil, "agenda" => "pursue" }.to_json
        elsif full.include?("WORLD MEMORY")
          { "facts" => [], "people" => [], "places" => [] }.to_json
        elsif full.include?("filter stored facts")
          { "relevant" => [] }.to_json
        elsif full.include?("You voice ONE character")
          { "speak" => speak, "dialogue" => (speak ? { "summary" => "acts", "prose" => line.to_s } : nil) }.to_json
        else
          selector.to_json
        end
      end
    end.new
  end

  def npc(name:, subrole: "barkeep", properties: {})
    Npc.create!(name: name, subrole: subrole, location: loc, current_hp: 5, max_hp: 5, properties: properties)
  end

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

  describe "hard pre-check (mechanical selector skip)" do
    it "skips the selector LLM entirely when no candidate has agenda, debts, or disposition" do
      selector_called = false
      probe = Class.new do
        define_method(:complete) do |system:, user:, schema: nil|
          selector_called = true
          { "actor" => nil }.to_json
        end
      end.new
      context.llm_nuance = probe
      a = active_with(present: [ npc(name: "Idle Bo") ])   # no agenda, no debts, neutral
      expect(run(a, transcript)).to be_nil
      expect(selector_called).to be(false)
    end

    it "still consults the selector when a candidate has an agenda" do
      called = false
      probe = Class.new do
        define_method(:complete) do |system:, user:, schema: nil|
          called = true
          { "actor" => nil }.to_json
        end
      end.new
      context.llm_nuance = probe
      bo = npc(name: "Driven Bo")
      a = active_with(present: [ bo ], agendas: { bo.id => "wants to close the deal" })
      run(a, transcript)
      expect(called).to be(true)
    end

    it "counts an outstanding debt as material" do
      bo = npc(name: "Owed Bo")
      Obligation.create!(debtor: player, creditor: bo, kind: "coins", amount: 3,
                         terms: "Three coins for the room", game_time: 90)
      called = false
      probe = Class.new do
        define_method(:complete) do |system:, user:, schema: nil|
          called = true
          { "actor" => nil }.to_json
        end
      end.new
      context.llm_nuance = probe
      a = active_with(present: [ bo ])
      run(a, transcript)
      expect(called).to be(true)
    end
  end

  it "settles on the arrival turn (cooldown nil) without firing" do
    maren = npc(name: "Maren")
    a = active_with(present: [ maren ], agendas: { maren.id => "wants to warn the player" }, cooldown: nil)
    t = transcript
    expect(run(a, t)).to be_nil
    expect(t.tool_calls).to be_empty
    expect(a.initiative_cooldown).to eq(0) # armed; fires from next turn
  end

  it "fires through the FULL voicing: staged line (no Event row), mark_spoken, last_initiator recorded" do
    maren = npc(name: "Maren", subrole: "barkeep")
    a = active_with(present: [ maren ], agendas: { maren.id => "wants to warn the player about the docks" })
    context.llm_nuance = stub_llm(
      selector: { "actor" => "Maren", "cause" => "the stranger is heading for the docks" },
      line: "Maren sets down a mug. 'The docks aren't safe after dark.'"
    )
    t = transcript
    result = nil
    expect { result = run(a, t) }.not_to change(Event, :count)

    expect(result[:npc]).to eq(maren)
    expect(result[:beat]).to match(/docks aren't safe/)
    rec = t.tool_calls.find { |tc| tc["name"] == "propose_event" && tc.dig("result", "staged") }
    expect(rec).to be_present                       # the voicing's own staging, recorded for the turn log
    expect(a.spoken?(maren.id)).to be(true)          # a real speaking turn — thread ownership follows
    expect(a.last_initiator).to eq(maren.id)
  end

  it "appends nothing when the selector picks nobody" do
    maren = npc(name: "Maren")
    a = active_with(present: [ maren ], agendas: { maren.id => "wants to warn the player" })
    t = transcript
    expect(run(a, t)).to be_nil
    expect(names(t)).not_to include("propose_event")
  end

  it "returns nil when the voicing itself declines (speak=false survives the frame)" do
    maren = npc(name: "Maren")
    a = active_with(present: [ maren ], agendas: { maren.id => "watchful" })
    context.llm_nuance = stub_llm(selector: { "actor" => "Maren", "cause" => "sizing up the stranger" }, speak: false)
    expect(run(a, transcript)).to be_nil
  end

  it "leads a pronoun-opening beat with the actor's name (dangling-antecedent guard)" do
    gerd = npc(name: "Gerd Vegirsson", subrole: "guard")
    a = active_with(present: [ gerd ], agendas: { gerd.id => "wants the stranger gone" })
    context.llm_nuance = stub_llm(
      selector: { "actor" => "Gerd Vegirsson", "cause" => "the stranger lingers" },
      line: "She steps forward, hand resting on the pommel of her sword."
    )
    result = run(a, transcript)
    expect(result[:beat]).to eq("Gerd Vegirsson — She steps forward, hand resting on the pommel of her sword.")
  end

  it "ignores an invalid actor name the selector invents" do
    maren = npc(name: "Maren")
    a = active_with(present: [ maren ], agendas: { maren.id => "wants to warn the player" })
    context.llm_nuance = stub_llm(selector: { "actor" => "Ghost", "cause" => "boo" })
    t = transcript
    expect(run(a, t)).to be_nil
    expect(names(t)).not_to include("propose_event")
  end

  it "skips followers (they ride with the player, not initiative targets)" do
    ally = npc(name: "Bjorn", subrole: "fighter", properties: { "following_player" => true })
    a = active_with(present: [ ally ], agendas: { ally.id => "wants to chat" })
    context.llm_nuance = stub_llm(selector: { "actor" => "Bjorn", "cause" => "chat" })
    t = transcript
    expect(run(a, t)).to be_nil # no eligible candidates → selector not even consulted
    expect(t.tool_calls).to be_empty
  end

  it "excludes ONLY same-turn speakers (one turn per character per turn)" do
    maren = npc(name: "Maren")
    spoke_this_turn = {
      "name" => "propose_event",
      "args" => { "participants" => [
        { "character_id" => maren.id,  "role" => "actor" },
        { "character_id" => player.id, "role" => "participant" }
      ] },
      "result" => { "staged" => true }
    }
    a = active_with(present: [ maren ], agendas: { maren.id => "wants to warn the player" })
    context.llm_nuance = stub_llm(selector: { "actor" => "Maren", "cause" => "warn" }, line: "Maren speaks.")
    t = transcript([ spoke_this_turn ])
    expect(run(a, t)).to be_nil # she already had her voice this turn
  end

  it "the beat's voicing sees lines staged earlier this turn (same-turn visibility)" do
    maren = npc(name: "Maren")
    gerd  = npc(name: "Gerd", subrole: "guard")
    staged = {
      "name" => "propose_event",
      "args" => {
        "participants" => [ { "character_id" => maren.id, "role" => "actor" } ],
        "details"      => "Maren mutters: 'The cellar's flooded again.'"
      },
      "result" => { "staged" => true }
    }
    voicing_prompt = nil
    a = active_with(present: [ maren, gerd ], agendas: { gerd.id => "wants the flooding dealt with" })
    context.llm_nuance = Class.new do
      define_method(:complete) do |system:, user:, schema: nil|
        full = "#{system}\n#{user}"
        if full.include?("TAKING STOCK")
          { "assessment" => "holds", "disposition" => "hold", "mood" => nil, "agenda" => "pursue" }.to_json
        elsif full.include?("WORLD MEMORY")
          { "facts" => [], "people" => [], "places" => [] }.to_json
        elsif full.include?("filter stored facts")
          { "relevant" => [] }.to_json
        elsif full.include?("You voice ONE character")
          voicing_prompt = full
          { "speak" => true, "dialogue" => { "summary" => "acts", "prose" => "Gerd frowns. 'I'll see to the cellar.'" } }.to_json
        else
          { "actor" => "Gerd", "cause" => "the cellar flooding" }.to_json
        end
      end
    end.new

    result = run(a, transcript([ staged ]))
    expect(result[:npc]).to eq(gerd)
    expect(voicing_prompt).to include("The cellar's flooded again")
  end

  it "does NOT exclude the previous turn's initiator (rotation law killed — a 1-on-1 can re-fire)" do
    maren = npc(name: "Maren")
    a = active_with(present: [ maren ], agendas: { maren.id => "wants the tab settled" }, last_initiator: maren.id)
    context.llm_nuance = stub_llm(
      selector: { "actor" => "Maren", "cause" => "the tab is still unpaid" },
      line: "Maren plants the saw. 'We settle up. Now.'"
    )
    result = run(a, transcript)
    expect(result[:npc]).to eq(maren)
  end

  it "surfaces a candidate's open debts to the selector (mechanical grounds for a beat)" do
    maren = npc(name: "Maren")
    Obligation.create!(debtor: player, creditor: maren, kind: "coins", amount: 9,
                       terms: "For the mended cloak", game_time: 0)
    selector_prompt = nil
    context.llm_nuance = Class.new do
      define_method(:complete) do |system:, user:, schema: nil|
        selector_prompt = user unless user.include?("You voice ONE character")
        { "actor" => nil, "cause" => "" }.to_json
      end
    end.new
    a = active_with(present: [ maren ], agendas: {})
    run(a, transcript)
    expect(selector_prompt).to include("Hero owes you 9 coins — For the mended cloak")
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
    context.llm_nuance = stub_llm(selector: { "actor" => "Vek", "cause" => "robbery" })
    t = transcript
    expect(run(a, t)).to be_nil
    expect(names(t)).not_to include("propose_event")
  end
end
