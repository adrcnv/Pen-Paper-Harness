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
      { "dialogue_events" => [ { "actor_id" => barkeep.id, "summary" => "greets the player", "prose" => "Aye, what'll it be?" } ],
        "resolve_call" => nil, "ignorance" => [] }.to_json
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
      { "dialogue_events" => [ { "actor_id" => barkeep.id, "summary" => "warns", "prose" => "Cross me and you'll regret it." } ],
        "resolve_call" => nil, "ignorance" => [],
        "memorable" => { "actor_id" => barkeep.id, "gist" => "Tomas threatened the player over the dock debt" } }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    expect {
      described_class.new.run(context: ctx, scene: scene, input: "I'm not paying", step: step)
    }.to change(Event, :count).by(1)

    ev = Event.last
    expect(ev.details.to_s).to match(/threatened the player over the dock debt/)
    expect(ev.event_participants.pluck(:character_id)).to include(barkeep.id, player.id)
  end

  it "fires a persuasion resolve when the model asks for one" do
    ctx = context_with do
      { "dialogue_events" => [],
        "resolve_call" => { "actor_id" => player.id, "stat" => "charisma", "action" => "press for the secret", "target_id" => barkeep.id, "difficulty" => "moderate" },
        "ignorance" => [] }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "tell me who runs the docks", step: step)
    expect(outcome.tool_calls.map { |t| t["name"] }).to include("resolve")
  end

  it "records asserted ignorance as a personal-scope event" do
    ctx = context_with do
      { "dialogue_events" => [],
        "resolve_call" => nil,
        "ignorance" => [ { "actor_id" => barkeep.id, "topic" => "the Shadow Hand" } ] }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "heard of the Shadow Hand?", step: step)
    ev = Event.where(scope: "personal").last
    expect(ev.details.to_s).to match(/have not heard of the Shadow Hand/)
  end

  it "realizes a claimed person into a grounded row (GROUND v0)" do
    # The barkeep names a contact who has no row. The runner should surface it
    # as a claim and the realizer should mint a findable character + a
    # `realize_claim` tool_call, without touching the no-invention restraint.
    allow(Harness::Character::Hatchery).to receive(:spawn) do |**kw|
      Npc.create!(name: kw[:name], subrole: kw[:subrole], location: kw[:location], properties: kw[:properties] || {})
    end
    ctx = context_with do
      { "dialogue_events" => [ { "actor_id" => barkeep.id, "summary" => "points the way", "prose" => "Ask for Harek at the relay." } ],
        "resolve_call" => nil, "ignorance" => [],
        "claims" => [ { "actor_id" => barkeep.id, "name" => "Harek", "subrole" => "contact", "gist" => "the relay contact" } ] }.to_json
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
      { "dialogue_events" => [ { "actor_id" => barkeep.id, "summary" => "points the way", "prose" => "Ask for Harek." } ],
        "resolve_call" => nil, "ignorance" => [],
        "claims" => [ { "actor_id" => barkeep.id, "name" => "Harek", "subrole" => "contact" } ] }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    expect {
      described_class.new.run(context: ctx, scene: scene, input: "who?", step: step)
    }.not_to change(Npc, :count)
    expect(Harness::Character::Hatchery).not_to have_received(:spawn)
  end

  it "exposes the live thread and the NPC's personality/mood/agenda to the emit" do
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
      llm_nuance: StubLLM.new { |user| captured = user; { "dialogue_events" => [], "resolve_call" => nil, "ignorance" => [] }.to_json })
    ctx.active_scene = active
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "still here", step: step)

    expect(captured).to include("exchange_so_far", "who runs this place?")          # the thread
    expect(captured).to include("gruff, taciturn", "wary of strangers", "wants the player to drink or leave") # the soul
  end

  it "re-dispatches when no NPC is present" do
    empty = Location.create!(name: "Empty Road")
    player.update!(location: empty)
    ctx = context_with { "{}" }
    ctx.player_location = empty
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "hello?", step: step)
    expect(outcome.status).to eq(:redispatch)
  end

  it "re-dispatches (no crash) on unparseable emit" do
    ctx = context_with { "definitely not json" }
    scene = Harness::Tools::QueryScene.build(ctx)
    outcome = described_class.new.run(context: ctx, scene: scene, input: "hi", step: step)
    expect(outcome.status).to eq(:redispatch)
  end

  # Regression: the runner used to hand the model truncated Ruby-inspect of the
  # whole `details` hash (it read top-level "trigger"/"summary"/"details", none
  # of which exist on a query_events row) — so a barkeep holding the town's
  # founding event still had "nothing interesting" to say. event_text now digs
  # the readable line out of details ({"summary"} and {"narrative"=>{...}}).
  it "passes CLEAN, readable event text to the model (not truncated hash-inspect)" do
    summary_ev = Event.create!(game_time: 50, scope: "local", location: tavern,
      details: { "summary" => "The founder drives the first pilings into the marsh, founding the town." })
    EventParticipant.create!(event: summary_ev, character: barkeep, role: "actor")

    narrative_ev = Event.create!(game_time: 60, scope: "local", location: tavern,
      details: { "narrative" => { "trigger" => "the great flood", "details" => "The river took the lower docks one spring." } })
    EventParticipant.create!(event: narrative_ev, character: barkeep, role: "actor")

    captured = nil
    ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
      llm_nuance: StubLLM.new { |user|
        captured = user
        { "dialogue_events" => [], "resolve_call" => nil, "ignorance" => [] }.to_json
      })
    scene = Harness::Tools::QueryScene.build(ctx)
    described_class.new.run(context: ctx, scene: scene, input: "anything interesting?", step: step)

    expect(captured).to include("The founder drives the first pilings into the marsh")
    expect(captured).to include("the great flood")
    expect(captured).to include("The river took the lower docks one spring")
    # No raw hash-inspect leakage (the old mangled form).
    expect(captured).not_to include('"summary" =>')
    expect(captured).not_to include('"narrative" =>')
  end

  # Regression: speaking to an ambient extra used to be silently redirected to
  # the nearest real NPC. A dialogue_event referencing an extra_index now
  # materializes that figure and speaks AS it.
  describe "promoting an extra speaker" do
    let(:recruit_desc) { "a young recruit shivering by the hearth, trying to dry his socks" }

    it "materializes the extra and commits a dialogue event spoken by the new character" do
      ctx = context_with do
        { "dialogue_events" => [ { "extra_index" => 0, "subrole" => "recruit", "summary" => "stammers a reply", "prose" => "The young one mumbles a nervous answer." } ],
          "resolve_call" => nil, "ignorance" => [] }.to_json
      end
      ctx.active_scene = Harness::Scene::Active.new(
        location: tavern,
        snapshot: Harness::Scene::Assembler.for(location: tavern),
        extras: [ recruit_desc ]
      )
      scene = Harness::Tools::QueryScene.build(ctx)

      expect {
        @outcome = described_class.new.run(context: ctx, scene: scene, input: "talk to the recruit", step: step)
      }.to change(Npc, :count).by(1)

      pc = @outcome.tool_calls.find { |t| t["name"] == "propose_character" }
      new_id = pc.dig("result", "character_id")
      expect(pc.dig("args", "from_extra")).to eq(recruit_desc)

      dlg = @outcome.tool_calls.select { |t| t["name"] == "propose_event" }.find { |t| t.dig("args", "trigger") != "asserted ignorance" }
      actor_ids = dlg.dig("args", "participants").select { |p| p["role"] == "actor" }.map { |p| p["character_id"] }
      expect(actor_ids).to eq([ new_id ]) # the recruit speaks, not the barkeep
    end
  end
end
