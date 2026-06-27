require "rails_helper"

RSpec.describe Harness::Runners::Conversation do
  let(:tavern) { Location.create!(name: "The Drowned Rat") }
  let!(:player) { Player.create!(name: "Hero", location: tavern) }
  let!(:barkeep) { Npc.create!(name: "Tomas", subrole: "barkeep", location: tavern) }

  def context_with(&block)
    Harness::Turn::Context.new(player_location: tavern, llm_nuance: StubLLM.new(&block), game_time: 100)
  end

  def step(intent = "ask the barkeep") = Harness::Dispatcher::Step.new(runner: "conversation", intent: intent, args: {})

  it "stages dialogue for narration WITHOUT persisting it (no soul-pollution)" do
    ctx = context_with do
      { "speak" => true, "dialogue" => { "summary" => "greets the player", "prose" => "Aye, what'll it be?" } }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    expect {
      @outcome = described_class.new.run(context: ctx, scene: scene, input: "hello barkeep", step: step)
    }.not_to change(Event, :count)

    expect(@outcome.status).to eq(:ok)
    # narration still sees the line (a propose_event-shaped record), but it's marked staged
    say = @outcome.tool_calls.find { |t| t["name"] == "propose_event" }
    expect(say).to be_present
    expect(say.dig("args", "details")).to eq("Aye, what'll it be?")
    expect(say.dig("result", "staged")).to be(true)
  end

  it "persists a durable event only when the exchange is flagged memorable" do
    ctx = context_with do
      { "speak" => true,
        "dialogue" => { "summary" => "warns", "prose" => "Cross me and you'll regret it." },
        "memorable" => { "gist" => "Tomas threatened the player over the dock debt" } }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    expect {
      described_class.new.run(context: ctx, scene: scene, input: "I'm not paying", step: step)
    }.to change(Event, :count).by(1)

    ev = Event.last
    expect(ev.details.to_s).to match(/threatened the player over the dock debt/)
    expect(ev.event_participants.pluck(:character_id)).to include(barkeep.id, player.id)
  end

  it "fires a persuasion resolve when the character asks for one (player rolls, character is target)" do
    ctx = context_with do
      { "speak" => true, "dialogue" => nil,
        "resolve_call" => { "stat" => "charisma", "action" => "press for the secret", "difficulty" => "moderate" } }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "tell me who runs the docks", step: step)
    resolve = outcome.tool_calls.find { |t| t["name"] == "resolve" }
    expect(resolve).to be_present
    expect(resolve.dig("args", "actor_id")).to eq(player.id)
    expect(resolve.dig("args", "target_id")).to eq(barkeep.id)
  end

  it "records asserted ignorance as a personal-scope event" do
    ctx = context_with do
      { "speak" => true, "ignorance" => { "topic" => "the Shadow Hand" } }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "heard of the Shadow Hand?", step: step)
    ev = Event.where(scope: "personal").last
    expect(ev.details.to_s).to match(/have not heard of the Shadow Hand/)
  end

  it "realizes a claimed person into a grounded row (GROUND v0)" do
    allow(Harness::Character::Hatchery).to receive(:spawn) do |**kw|
      Npc.create!(name: kw[:name], subrole: kw[:subrole], location: kw[:location], properties: kw[:properties] || {})
    end
    ctx = context_with do
      { "speak" => true,
        "dialogue" => { "summary" => "points the way", "prose" => "Ask for Harek at the relay." },
        "claims" => { "name" => "Harek", "subrole" => "contact", "gist" => "the relay contact" } }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "who do I deliver to?", step: step)

    expect(outcome.status).to eq(:ok)
    claim_call = outcome.tool_calls.find { |t| t["name"] == "realize_claim" }
    expect(claim_call).to be_present
    expect(claim_call["result"]).to include("minted" => true)
    expect(Npc.find_by(name: "Harek")).to be_present
  end

  it "does not duplicate a claimed person who already exists" do
    allow(Harness::Character::Hatchery).to receive(:spawn).and_call_original
    Npc.create!(name: "Harek", subrole: "contact", location: tavern)
    ctx = context_with do
      { "speak" => true,
        "dialogue" => { "summary" => "points the way", "prose" => "Ask for Harek." },
        "claims" => { "name" => "Harek", "subrole" => "contact" } }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    expect {
      described_class.new.run(context: ctx, scene: scene, input: "who?", step: step)
    }.not_to change(Npc, :count)
    expect(Harness::Character::Hatchery).not_to have_received(:spawn)
  end

  it "exposes the live thread and the character's OWN personality/mood/agenda to its call" do
    barkeep.update!(properties: { "personality" => "gruff, taciturn" })
    active = Harness::Scene::Active.new(
      location: tavern, snapshot: nil,
      narrations: [ { "input" => "who runs this place?", "narration" => "Tomas grunts, says nothing." } ],
      internal_state: { barkeep.id => "wary of strangers" },
      agendas: { barkeep.id => "wants the player to drink or leave" },
      extras: [], entered_at_game_time: 90
    )
    captured = nil
    ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
      llm_nuance: StubLLM.new { |full| captured = full; { "speak" => false }.to_json })
    ctx.active_scene = active
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "still here", step: step)

    expect(captured).to include("exchange_so_far", "who runs this place?")          # the shared thread
    expect(captured).to include("gruff, taciturn", "wary of strangers", "wants the player to drink or leave") # the soul
  end

  it "does NOT expose another present character's private events to a character's call (theory-of-mind boundary)" do
    # Ysme holds a PERSONAL-scope memory (private — not local-public, so it isn't
    # shared by being-in-the-room). When the barkeep is voiced, Ysme's memory
    # must not appear in his prompt — only the public roster entry (name + role).
    # It MUST still reach Ysme's own call: same event, holder sees it, others don't.
    ysme = Npc.create!(name: "Ysme", subrole: "bouncer", location: tavern)
    secret = Event.create!(game_time: 50, scope: "personal", location: tavern,
      details: { "summary" => "Ysme hauled the rogue barge off the pilings in the storm." })
    EventParticipant.create!(event: secret, character: ysme, role: "actor")

    seen = []
    ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
      llm_nuance: StubLLM.new { |full| seen << full; { "speak" => false }.to_json })
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "anything interesting, barkeep?", step: step("ask the barkeep"))

    # Key on the holder id — it appears ONLY in that character's own `you`
    # block (the roster carries names + roles, no ids), so this picks the right call.
    barkeep_call = seen.find { |s| s.include?(%("id": #{barkeep.id},)) }
    ysme_call    = seen.find { |s| s.include?(%("id": #{ysme.id},)) }
    expect(barkeep_call).to be_present
    expect(barkeep_call).to include("Ysme")                                  # public identity is fine
    expect(barkeep_call).not_to include("hauled the rogue barge")            # private knowledge is NOT
    expect(ysme_call).to include("hauled the rogue barge")                   # but the holder DOES have it
  end

  it "stops after two characters have spoken (early exit)" do
    # Four present; if two answer, the rest are never polled.
    Npc.create!(name: "Ada", subrole: "patron", location: tavern)
    Npc.create!(name: "Bo", subrole: "patron", location: tavern)
    Npc.create!(name: "Cy", subrole: "patron", location: tavern)
    polled = []
    ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
      llm_nuance: StubLLM.new { |full| polled << full; { "speak" => true, "dialogue" => { "summary" => "hi", "prose" => "Hello." } }.to_json })
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "hello everyone", step: step("greet the room"))
    expect(polled.size).to eq(2)
  end

  it "re-dispatches when no one is present" do
    empty = Location.create!(name: "Empty Road")
    player.update!(location: empty)
    ctx = context_with { "{}" }
    ctx.player_location = empty
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "hello?", step: step)
    expect(outcome.status).to eq(:redispatch)
  end

  it "re-dispatches (no crash) when every voice emit is unparseable" do
    ctx = context_with { "definitely not json" }
    scene = Harness::Tools::QueryScene.build(ctx)
    outcome = described_class.new.run(context: ctx, scene: scene, input: "hi", step: step)
    expect(outcome.status).to eq(:redispatch)
  end

  # Regression: the runner used to hand the model truncated Ruby-inspect of the
  # whole `details` hash. event_text now digs the readable line out of details.
  it "passes CLEAN, readable event text to the character's call (not truncated hash-inspect)" do
    summary_ev = Event.create!(game_time: 50, scope: "local", location: tavern,
      details: { "summary" => "The founder drives the first pilings into the marsh, founding the town." })
    EventParticipant.create!(event: summary_ev, character: barkeep, role: "actor")

    narrative_ev = Event.create!(game_time: 60, scope: "local", location: tavern,
      details: { "narrative" => { "trigger" => "the great flood", "details" => "The river took the lower docks one spring." } })
    EventParticipant.create!(event: narrative_ev, character: barkeep, role: "actor")

    captured = nil
    ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
      llm_nuance: StubLLM.new { |full| captured = full; { "speak" => false }.to_json })
    scene = Harness::Tools::QueryScene.build(ctx)
    described_class.new.run(context: ctx, scene: scene, input: "anything interesting?", step: step)

    expect(captured).to include("The founder drives the first pilings into the marsh")
    expect(captured).to include("the great flood")
    expect(captured).to include("The river took the lower docks one spring")
    expect(captured).not_to include('"summary" =>')
    expect(captured).not_to include('"narrative" =>')
  end

  # Regression: speaking to an ambient extra materializes that figure and speaks
  # AS it (rather than redirecting to the nearest real NPC).
  describe "promoting an extra speaker" do
    let(:recruit_desc) { "a young recruit shivering by the hearth, trying to dry his socks" }

    it "materializes the extra and stages a dialogue line spoken by the new character" do
      ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
        llm_nuance: StubLLM.new { |full|
          if full.include?(recruit_desc)   # only the extra's own call carries its description
            { "speak" => true, "subrole" => "recruit",
              "dialogue" => { "summary" => "stammers a reply", "prose" => "The young one mumbles a nervous answer." } }.to_json
          else
            { "speak" => false }.to_json   # the barkeep stays out of it
          end
        })
      ctx.active_scene = Harness::Scene::Active.new(
        location: tavern,
        snapshot: Harness::Scene::Assembler.for(location: tavern),
        extras: [ recruit_desc ]
      )
      scene = Harness::Tools::QueryScene.build(ctx)

      expect {
        @outcome = described_class.new.run(context: ctx, scene: scene, input: "talk to the recruit", step: step("address the recruit"))
      }.to change(Npc, :count).by(1)

      pc = @outcome.tool_calls.find { |t| t["name"] == "propose_character" }
      new_id = pc.dig("result", "character_id")
      expect(pc.dig("args", "from_extra")).to eq(recruit_desc)

      say = @outcome.tool_calls.find { |t| t["name"] == "propose_event" && t.dig("result", "staged") }
      actor_ids = say.dig("args", "participants").select { |p| p["role"] == "actor" }.map { |p| p["character_id"] }
      expect(actor_ids).to eq([ new_id ]) # the recruit speaks, not the barkeep
    end
  end
end
