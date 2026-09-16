require "rails_helper"

RSpec.describe Harness::Runners::Conversation do
  let(:tavern) { Location.create!(name: "The Drowned Rat") }
  let!(:player) { Player.create!(name: "Hero", location: tavern) }
  let!(:barkeep) { Npc.create!(name: "Tomas", subrole: "barkeep", location: tavern) }

  # The act judge (the speaker's hands) answers "none" for every speaker
  # unless a spec routes it itself (see "the hands" below): the rest of the
  # file is about the voice, and its stubs count and inspect prompts.
  ACT_MARK = "DID with their hands"
  NONE = { "act" => "none", "to_id" => nil, "coins" => nil, "item_id" => nil, "item" => nil, "category" => nil, "place_id" => nil }.freeze
  # The contest judge (kind, party, same ask) answers "none" — plain talk —
  # unless a spec routes it itself (see "the contest" below).
  KIND_MARK = "CONTEST: KIND"
  NO_CONTEST = { "reasoning" => "plain talk", "kind" => "none", "with_id" => nil, "same_as" => nil }.freeze
  # The chime-in gate (a bystander's one question) answers no unless a spec routes it.
  CHIME_MARK = "CHIME IN?"
  NO_CHIME = { "reasoning" => "nothing to add", "chime_in" => false }.freeze

  def context_with(&block)
    routed = ->(full) {
      if full.include?(ACT_MARK) then NONE.to_json
      elsif full.include?(KIND_MARK) then NO_CONTEST.to_json
      elsif full.include?(CHIME_MARK) then NO_CHIME.to_json
      else block.call(full)
      end
    }
    Harness::Turn::Context.new(player_location: tavern, llm_nuance: StubLLM.new(&routed), game_time: 100)
  end

  def step(intent = "ask the barkeep") = Harness::Dispatcher::Step.new(runner: "conversation", intent: intent, args: {})
  # A step whose words the plan addressed to one present character (by id) or one painted figure (by index).
  def step_to(id, figure: nil) = Harness::Dispatcher::Step.new(runner: "conversation", intent: "talk", args: { "with_id" => id, "figure" => figure }.compact)
  # A voicing prompt, as opposed to any judge's (act, contest, memory, taking stock, recall).
  def voicing?(p) = !(p.include?("WORLD MEMORY") || p.include?("TAKING STOCK") || p.include?("filter stored facts") || p.include?(ACT_MARK) || p.include?("CONTEST") || p.include?(CHIME_MARK))

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

  it "with no named character here and no painted figure addressed, the turn is an honest silence — not a redispatch" do
    barkeep.update!(location: Location.create!(name: "Elsewhere"))
    ctx = context_with { raise "no voice should be called" }
    ctx.active_scene = Harness::Scene::Active.new(location: tavern, snapshot: Harness::Scene::Assembler.for(location: tavern), extras: [ "a fisherman nursing a mug in the corner" ])
    outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "approach the bar. \"I'll buy a mug of ale.\"", step: step)
    expect(outcome.status).to eq(:ok)
    silence = outcome.tool_calls.find { |t| t["name"] == "conversation_silence" }
    expect(silence.dig("result", "nobody_here")).to be(true)
  end

  it "retries a malformed emit once with the defect named and stages the corrected line" do
    calls = 0
    ctx = context_with do |full|
      calls += 1
      if (full.include?("SECOND PASS: WORLD MEMORY") || full.include?("TAKING STOCK"))    # post-turn reflection — not under test here
        { "facts" => [], "people" => [], "places" => [] }.to_json
      elsif full.include?("--- RETRY ---")
        expect(full).to include('"speak" is true but dialogue.prose is missing', '"pro"')
        { "speak" => true, "dialogue" => { "summary" => "greets", "prose" => "Aye, what'll it be?" } }.to_json
      else
        { "speak" => true, "dialogue" => { "summary" => "greets", "pro" => "Aye, what'll it be?" } }.to_json
      end
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "hello barkeep", step: step)
    say = outcome.tool_calls.find { |t| t["name"] == "propose_event" }
    expect(say.dig("args", "details")).to eq("Aye, what'll it be?")
  end

  it "drops the line when the retry is also malformed (no infinite bounce)" do
    voicing_calls = 0
    ctx = context_with do |full|
      voicing_calls += 1 unless (full.include?("WORLD MEMORY") || full.include?("TAKING STOCK"))
      "not json at all"
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "hello barkeep", step: step)
    expect(outcome.tool_calls.find { |t| t["name"] == "propose_event" }).to be_nil
    expect(voicing_calls).to eq(2) # original + exactly one retry
  end

  it "keeps text-less mechanical events OUT of the you-block (no bare cast-suffix resurrection)" do
    ev = Event.create!(game_time: 60, scope: "personal", location_id: tavern.id,
                       details: { "resolve" => { "outcome" => "failure", "stat" => "charisma" } })
    [ barkeep, player ].each { |c| EventParticipant.create!(event: ev, character: c, role: "participant") }
    voicing = nil
    ctx = context_with do |full|
      if (full.include?("WORLD MEMORY") || full.include?("TAKING STOCK"))
        { "facts" => [], "people" => [], "places" => [] }.to_json
      elsif full.include?("filter stored facts")
        { "relevant" => [] }.to_json
      else
        voicing ||= full
        { "speak" => true, "dialogue" => { "summary" => "nods", "prose" => "Aye." } }.to_json
      end
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "hello barkeep", step: step)
    expect(voicing).not_to include('" (with')
  end

  it "rides open obligations into the you-block as debts, from the speaker's seat" do
    Obligation.create!(debtor: player, creditor: barkeep, kind: "coins", amount: 12,
                       terms: "For the room", due: "by first light", game_time: 50)
    voicing = nil
    ctx = context_with do |full|
      if (full.include?("WORLD MEMORY") || full.include?("TAKING STOCK"))
        { "facts" => [], "people" => [], "places" => [] }.to_json
      elsif full.include?("filter stored facts")
        { "relevant" => [] }.to_json
      else
        voicing ||= full
        { "speak" => true, "dialogue" => { "summary" => "presses", "prose" => "You still owe for the room." } }.to_json
      end
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "hello barkeep", step: step)
    expect(voicing).to include("Hero owes Tomas 12 coins — For the room — due: by first light")
  end

  it "renders an event's cast into the you-block line, excluding the holder (participation as visible links)" do
    vesna = Npc.create!(name: "Vesna", subrole: "trader", location: tavern)
    ev = Event.create!(game_time: 50, scope: "personal", location_id: tavern.id,
                       details: { "narrative" => { "trigger" => "shared a smoke", "details" => "Talked over the fence about the flood." } })
    [ barkeep, vesna, player ].each { |c| EventParticipant.create!(event: ev, character: c, role: "participant") }

    voicing = nil
    ctx = context_with do |full|
      if (full.include?("WORLD MEMORY") || full.include?("TAKING STOCK"))
        { "facts" => [], "people" => [], "places" => [] }.to_json
      elsif full.include?("filter stored facts")
        { "relevant" => [] }.to_json
      else
        voicing ||= full   # first voicing = Tomas (addressed); Vesna's chime-in poll comes after
        { "speak" => true, "dialogue" => { "summary" => "chats", "prose" => "Aye." } }.to_json
      end
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "hello barkeep", step: step)
    expect(voicing).to include("(with Hero, Vesna)")           # cast surfaced, holder (Tomas) excluded
    expect(voicing).not_to include("(with Tomas")
  end

  it "a second speaker sees the first speaker's just-staged line as the current exchange entry" do
    Npc.create!(name: "Ruta", subrole: "servant", location: tavern)
    voicings = []
    ctx = context_with do |full|
      if (full.include?("WORLD MEMORY") || full.include?("TAKING STOCK"))
        { "facts" => [], "people" => [], "places" => [] }.to_json
      elsif full.include?("filter stored facts")
        { "relevant" => [] }.to_json
      else
        voicings << full
        if voicings.size == 1
          { "speak" => true, "dialogue" => { "summary" => "answers", "prose" => "The ferry sank on Tuesday, that's what's new." } }.to_json
        else
          { "speak" => false }.to_json
        end
      end
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "any news, folks?", step: step("asks the room"))
    expect(voicings.size).to eq(2)
    expect(voicings[0]).not_to include("ferry sank")                          # first speaker: thread unchanged
    expect(voicings[1]).to include("The ferry sank on Tuesday")               # second speaker sees it...
    expect(voicings[1].split("exchange_so_far").last).to include("any news, folks?") # ...as this turn's entry
  end

  # The standing doing was performed verbatim as the opening gesture of every
  # line. The voicing gets it until the first line, then only when refreshed.
  it "hands the voicing `doing` before the first line, hides it afterwards until taking-stock refreshes it" do
    payloads = []
    ctx = context_with do |full|
      if full.include?("TAKING STOCK")
        { "assessment" => "holds", "disposition" => "hold", "mood" => nil, "agenda" => "pursue", "doing" => nil }.to_json
      elsif full.include?("WORLD MEMORY")
        { "facts" => [], "people" => [], "places" => [] }.to_json
      else
        payloads << full
        { "speak" => true, "dialogue" => { "summary" => "talks", "prose" => "Tomas nods. \"Line #{payloads.size}.\"" } }.to_json
      end
    end
    ctx.active_scene = Harness::Scene::Active.new(location: tavern, snapshot: Harness::Scene::Assembler.for(location: tavern),
                                                  narrations: [], extras: [], doing: { barkeep.id => "wiping mugs" })
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "hello", step: step)
    expect(payloads[0]).to match(/"doing": "wiping mugs"/)          # seed, first line
    described_class.new.run(context: ctx, scene: scene, input: "and?", step: step)
    expect(payloads[1]).not_to match(/^\s+"doing": "/)                # spoken, nothing refreshed
    ctx.active_scene.update_doing!(barkeep.id, "counting coin")
    described_class.new.run(context: ctx, scene: scene, input: "well?", step: step)
    expect(payloads[2]).to match(/"doing": "counting coin"/)         # refreshed since the last line
  end

  # The judge often returns the current doing word for word; stored as a
  # shift it re-fed the voicing and logged a shift the eyes never saw.
  it "a taking-stock doing equal to the current one is a hold: nothing dirtied, nothing re-fed" do
    payloads = []
    ctx = context_with do |full|
      if full.include?("TAKING STOCK")
        { "assessment" => "holds", "disposition" => "hold", "mood" => nil, "agenda" => "pursue", "doing" => "wiping mugs" }.to_json
      elsif full.include?("WORLD MEMORY")
        { "facts" => [], "people" => [], "places" => [] }.to_json
      else
        payloads << full
        { "speak" => true, "dialogue" => { "summary" => "talks", "prose" => "Tomas nods. \"Line #{payloads.size}.\"" } }.to_json
      end
    end
    ctx.active_scene = Harness::Scene::Active.new(location: tavern, snapshot: Harness::Scene::Assembler.for(location: tavern),
                                                  narrations: [], extras: [], doing: { barkeep.id => "wiping mugs" })
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "hello", step: step)
    expect(ctx.active_scene.doing_dirty).to be_blank
    described_class.new.run(context: ctx, scene: scene, input: "and?", step: step)
    expect(payloads[1]).not_to match(/^\s+"doing": "/)
  end

  # Continuity: an unnamed follow-up goes first to whoever spoke last turn,
  # who is told so — both NPCs read "no name" as "not addressed" and a
  # direct follow-up went unanswered (2026-09-12).
  it "polls last turn's speaker first on an unnamed line and tells them they spoke last" do
    ruta = Npc.create!(name: "Ruta", subrole: "servant", location: tavern)
    seen = []
    ctx = context_with do |full|
      next({ "facts" => [] }.to_json) if (full.include?("WORLD MEMORY") || full.include?("TAKING STOCK"))
      next({ "relevant" => [] }.to_json) if full.include?("filter stored facts")
      seen << full
      if full.include?(%("id": #{ruta.id},))
        { "speak" => true, "dialogue" => { "summary" => "answers", "prose" => "Ruta shrugs. \"Roads are quiet, mostly.\"" } }.to_json
      else
        { "speak" => false }.to_json
      end
    end
    ctx.active_scene = Harness::Scene::Active.new(location: tavern, snapshot: Harness::Scene::Assembler.for(location: tavern),
                                                  narrations: [], extras: [])
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "Ruta, anything on the roads?", step: step_to(ruta.id))   # addressed: Ruta speaks
    expect(ctx.active_scene.last_speakers).to eq([ ruta.id ])
    seen.clear
    described_class.new.run(context: ctx, scene: scene, input: "any beasts on the ridge?", step: step)      # unnamed follow-up
    expect(seen.first).to include(%("id": #{ruta.id},)).and match(/^\s+"spoke_last": true/)   # Ruta first, told so (payload line, not the prompt's shape)
    expect(seen.last).not_to match(/^\s+"spoke_last": true/)                                   # Tomas is not
  end

  # The first speaker of a turn is judged before the current input joins the
  # thread; without the player's line the bargains judge booked an NPC's
  # fresh offer as a debt the player owed (2026-09-12).
  it "hands the bargains judge the player's line for THIS turn on its own" do
    ledger_users = []
    ctx = context_with do |full|
      if full.include?("BARGAINS")
        ledger_users << full
        { "deals" => [], "discharged" => [] }.to_json
      elsif full.include?("WORLD MEMORY") || full.include?("TAKING STOCK")
        { "facts" => [], "people" => [], "places" => [] }.to_json
      else
        { "speak" => true, "dialogue" => { "summary" => "offers", "prose" => "Tomas shrugs. \"Two silver if you haul it.\"" } }.to_json
      end
    end
    scene = Harness::Tools::QueryScene.build(ctx)
    described_class.new.run(context: ctx, scene: scene, input: "any work going?", step: step)
    expect(ledger_users.size).to eq(1)
    expect(ledger_users.first).to include('"player_said_now": "any work going?"')
  end

  # The tail (two judges + taking-stock) used to run between speakers, which
  # fed speaker B the row just minted from speaker A's line on top of the line
  # itself — the same-turn echo amplifier (2026-09-12).
  it "runs every speaker's tail (judges + taking-stock) after the LAST speaker is voiced, never between speakers" do
    Npc.create!(name: "Ruta", subrole: "servant", location: tavern)
    calls = []
    ctx = context_with do |full|
      if full.include?("WORLD MEMORY") || full.include?("TAKING STOCK")
        calls << :tail
        { "facts" => [], "people" => [], "places" => [], "deals" => [], "discharged" => [] }.to_json
      elsif full.include?("filter stored facts")
        { "relevant" => [] }.to_json
      else
        calls << :voice
        line = calls.count(:voice) == 1 ? "The ferry sank on Tuesday." : "And the miller went down with it."
        { "speak" => true, "dialogue" => { "summary" => "speaks", "prose" => line } }.to_json
      end
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "any news, folks?", step: step("asks the room"))
    expect(calls.count(:voice)).to eq(2)
    expect(calls.count(:tail)).to be >= 2
    expect(calls.index(:tail)).to be > calls.rindex(:voice)
  end

  it "the plan's addressee is polled first and marked addressed; a name in the input alone is not a ruling (A1 binds it)" do
    bruna = Npc.create!(name: "Bruna", subrole: "fisher", location: tavern)
    polled = []
    ctx = context_with { |full| polled << full if voicing?(full); { "speak" => false }.to_json }
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "Bruna, who are you all waiting for?", step: step)
    first_you = polled.first.split('"you"').last
    expect(first_you).to include(barkeep.name)      # roster order, nobody addressed by the plan
    expect(first_you).not_to include(bruna.name)

    polled.clear
    described_class.new.run(context: ctx, scene: scene, input: "who are you all waiting for?", step: step_to(bruna.id))
    expect(polled.first.split('"you"').last).to include(bruna.name)   # the addressee first
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

  # Two judges must agree that a line is a press: the planner (from the
  # player's words) AND the character (from its own seat). The character
  # asked for dice on plain questions too (probe 3), so alone it rolls nothing.
  it "does not roll on a character's guarded read alone (no planner-bound check)" do
    expect(Harness::Dice).not_to receive(:check)
    ctx = context_with do
      { "speak" => true, "dialogue" => { "summary" => "stalls", "prose" => "Tomas says nothing of the docks." }, "guarded" => true }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "tell me who runs the docks", step: step)
    expect(outcome.tool_calls.find { |t| t["name"] == "resolve" }).to be_nil
  end

  # Named people are now realized by the post-turn Knowledge::Capture pass (the
  # single entity pipe), not a per-emit `claims` field. The capture LLM returns
  # a `people` list; capture hands each to the Realizer.
  def capture_people(*people, dialogue: "Ask for Harek at the relay.")
    context_with do |full|
      if (full.include?("WORLD MEMORY") || full.include?("TAKING STOCK"))
        { "facts" => [], "people" => people }.to_json
      else
        { "speak" => true, "dialogue" => { "summary" => "points", "prose" => dialogue } }.to_json
      end
    end
  end

  it "realizes a person named in dialogue via the capture pipe" do
    allow(Harness::Character::Hatchery).to receive(:spawn) do |**kw|
      Npc.create!(name: kw[:name], subrole: kw[:subrole], location: kw[:location], properties: kw[:properties] || {})
    end
    ctx = capture_people({ "name" => "Harek", "subrole" => "contact", "gist" => "the relay contact", "by" => "Tomas" })
    scene = Harness::Tools::QueryScene.build(ctx)

    expect {
      described_class.new.run(context: ctx, scene: scene, input: "who do I deliver to?", step: step)
    }.to change(Npc, :count).by(1)
    expect(Npc.find_by(name: "Harek")).to be_present
  end

  it "realizes a ROLE-reference person with no name (the picker names them) via capture" do
    allow(Harness::Character::Hatchery).to receive(:spawn) do |**kw|
      Npc.create!(name: kw[:name], subrole: kw[:subrole], location: kw[:location], properties: kw[:properties] || {})
    end
    ctx = capture_people({ "subrole" => "courier", "gist" => "the speaker's brother who runs the relay", "by" => "Tomas" },
                         dialogue: "My brother runs the relay — ask for him.")
    scene = Harness::Tools::QueryScene.build(ctx)

    expect {
      described_class.new.run(context: ctx, scene: scene, input: "who runs the relay?", step: step)
    }.to change(Npc, :count).by(1)
  end

  it "does not duplicate a person who already exists (links instead) via capture" do
    allow(Harness::Character::Hatchery).to receive(:spawn).and_call_original
    Npc.create!(name: "Harek", subrole: "contact", location: tavern)
    ctx = capture_people({ "name" => "Harek", "subrole" => "contact", "by" => "Tomas" })
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

  it "a decliner's silent snub lands on the scene: speak false + doing writes the microbeat" do
    active = Harness::Scene::Active.new(location: tavern, snapshot: nil, narrations: [],
                                        internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 90)
    ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
      llm_nuance: StubLLM.new { { "speak" => false, "doing" => "turns back to his ropes" }.to_json })
    ctx.active_scene = active
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "well?!", step: step)

    expect(active.doing_for(barkeep.id)).to eq("turns back to his ropes")
    # Still a declined turn — nothing staged, silence marker set.
    expect(outcome.tool_calls.map { |t| t["name"] }).to include("conversation_silence")
  end

  it "a decliner sees their own current doing (the reference for 'simply carry on')" do
    active = Harness::Scene::Active.new(location: tavern, snapshot: nil, narrations: [],
                                        internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 90)
    active.update_doing!(barkeep.id, "tracing his ledger columns")
    captured = nil
    ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
      llm_nuance: StubLLM.new { |full| captured = full; { "speak" => false }.to_json })
    ctx.active_scene = active
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "still here", step: step)
    expect(captured).to include("tracing his ledger columns")
  end

  it "keeps mood/agenda in the payload after the NPC has spoken (the taking-stock pass keeps them current)" do
    barkeep.update!(properties: { "personality" => "gruff, taciturn" })
    active = Harness::Scene::Active.new(
      location: tavern, snapshot: nil, narrations: [],
      internal_state: { barkeep.id => "wary of strangers" },
      agendas: { barkeep.id => "wants the player to drink or leave" },
      extras: [], entered_at_game_time: 90
    )
    voicings = []
    ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
      llm_nuance: StubLLM.new { |full|
        if full.include?("TAKING STOCK")
          { "assessment" => "Tomas holds.", "disposition" => "hold", "mood" => nil, "agenda" => "pursue" }.to_json
        elsif full.include?("WORLD MEMORY")
          { "facts" => [], "people" => [], "places" => [] }.to_json
        elsif full.include?(ACT_MARK)
          NONE.to_json
        else
          voicings << full
          { "speak" => true, "dialogue" => { "summary" => "hi", "prose" => "What'll it be?" } }.to_json
        end
      })
    ctx.active_scene = active
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "hello", step: step)
    expect(voicings.last).to include("wary of strangers", "wants the player to drink or leave")
    expect(active.spoken?(barkeep.id)).to be(true)

    # Second turn, same scene: mood/agenda STILL ride — no longer frozen
    # seeds, the reevaluation owns keeping them honest.
    voicings.clear
    described_class.new.run(context: ctx, scene: scene, input: "still here", step: step)
    expect(voicings.last).to include("wary of strangers", "wants the player to drink or leave", "gruff, taciturn")
  end

  it "strips an echoed disposition prefix from the eval's mood before storing (no 'guarded — guarded —' pileup)" do
    active = Harness::Scene::Active.new(
      location: tavern, snapshot: nil, narrations: [],
      internal_state: { barkeep.id => "easy, wiping the bar" },
      agendas: {}, extras: [], entered_at_game_time: 90
    )
    ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
      llm_nuance: StubLLM.new { |full|
        if full.include?("TAKING STOCK")
          { "assessment" => "Tomas cools.", "disposition" => "hold",
            "mood" => "guarded — watching the stranger's hands", "agenda" => "pursue" }.to_json
        elsif full.include?("WORLD MEMORY")
          { "facts" => [], "people" => [], "places" => [] }.to_json
        else
          { "speak" => true, "dialogue" => { "summary" => "grunts", "prose" => "Hm." } }.to_json
        end
      })
    ctx.active_scene = active
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "hello barkeep", step: step)
    expect(active.state_for(barkeep.id)).to eq("watching the stranger's hands")
  end

  it "takes stock in two clean judges: the inner one on the persona, both lines, the receipts and the settled verdict; the hands one on the line, the receipts and the current doing" do
    Item.create!(name: "jug of cider", subrole: "drink", location: tavern, properties: { "tags" => %w[provision drink], "modifiers" => [], "effects" => [], "for_sale" => true, "seller_id" => barkeep.id })
    barkeep.update!(properties: { "personality" => "slow to warm, quick to sulk" })
    active = Harness::Scene::Active.new(location: tavern, snapshot: nil, narrations: [], internal_state: { barkeep.id => "easy, wiping the bar" },
                                        agendas: { barkeep.id => "get the stranger to buy a drink" }, doing: { barkeep.id => "wiping mugs" }, extras: [], entered_at_game_time: 90)
    seen = []
    ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
      llm_nuance: StubLLM.new { |full|
        seen << full
        if full.include?("TAKING STOCK: INNER")
          { "reasoning" => "sold a jug, warms a touch", "disposition" => "warmer", "mood" => "pleased with the coin", "agenda" => "resolved" }.to_json
        elsif full.include?("TAKING STOCK: HANDS")
          { "reasoning" => "back to the mugs", "doing" => "racking the clean mugs" }.to_json
        elsif full.include?("WORLD MEMORY")
          { "facts" => [], "people" => [], "places" => [] }.to_json
        elsif full.include?(ACT_MARK)
          NONE.merge("act" => "give", "to_id" => player.id, "item_id" => Item.find_by(name: "jug of cider").id).to_json
        elsif full.include?(KIND_MARK)
          NO_CONTEST.to_json
        else
          { "speak" => true, "dialogue" => { "summary" => "sells", "prose" => "Tomas slides the jug over. \"There you are.\"" } }.to_json
        end
      })
    ctx.active_scene = active
    described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "I'll take the cider", step: step)

    inner = JSON.parse(seen.find { |p| p.include?("TAKING STOCK: INNER") }.split("INPUT:\n", 2).last)
    expect(inner["you"]).to eq("name" => "Tomas", "subrole" => "barkeep", "personality" => "slow to warm, quick to sulk",
                               "disposition" => "neutral", "mood" => "easy, wiping the bar", "agenda" => "get the stranger to buy a drink")
    expect(inner["player_said_now"]).to eq("I'll take the cider")
    expect(inner["you_said"]).to eq("Tomas slides the jug over. \"There you are.\"")
    expect(inner["this_turn"]).to include("Tomas hands you the jug of cider.")
    hands = JSON.parse(seen.find { |p| p.include?("TAKING STOCK: HANDS") }.split("INPUT:\n", 2).last)
    expect(hands["you"]).to eq("name" => "Tomas", "subrole" => "barkeep", "doing" => "wiping mugs")
    expect(hands).not_to have_key("player_said_now")
    expect(hands["this_turn"]).to include("Tomas hands you the jug of cider.")
    expect(active.disposition_for(barkeep.id)).to eq("warm")
    expect(active.state_for(barkeep.id)).to eq("pleased with the coin")
    expect(active.agenda_for(barkeep.id)).to be_nil
    expect(active.doing_for(barkeep.id)).to eq("racking the clean mugs")

    llm = ctx.llm_nuance
    i = llm.system_calls.index { |sys| sys.include?("TAKING STOCK: INNER") }
    expect(llm.sampling_calls[i]).to eq(temperature: 0.3, thinking: false, max_tokens: nil)
    c = described_class
    { c::STOCK_INNER_PATH => c::STOCK_INNER_SCHEMA, c::STOCK_HANDS_PATH => c::STOCK_HANDS_SCHEMA }.each do |path, schema|
      expect(schema["properties"].keys.first).to eq("reasoning")
      expect(schema["required"]).to eq(schema["properties"].keys)
      named = File.read(path).split("Output:", 2).last.scan(/"(\w+)":/).flatten.uniq
      expect(named.sort).to eq(schema["properties"].keys.sort), "#{File.basename(path)} names #{named.inspect}"
    end
  end

  it "a refused act is a fact the speaker's tail reads: 'Nothing changed hands: …' in the taking-stock and ledger receipts" do
    Npc.create!(name: "Ragnar", subrole: "labourer", location: tavern)
    barkeep.update!(location: Location.create!(name: "Elsewhere"))
    seen = []
    stub = StubLLM.new do |full|
      seen << full
      if full.include?(ACT_MARK) then NONE.merge("act" => "give", "to_id" => player.id, "item" => "a belt knife", "category" => "tools").to_json
      elsif full.include?(KIND_MARK) then NO_CONTEST.to_json
      elsif full.include?("WORLD MEMORY") || full.include?("TAKING STOCK") then { "facts" => [], "people" => [], "places" => [] }.to_json
      elsif full.include?("filter stored facts") then { "relevant" => [] }.to_json
      else { "speak" => true, "dialogue" => { "summary" => "hands it over", "prose" => "Ragnar draws his belt knife and holds it out. \"Here.\"" } }.to_json
      end
    end
    ctx = Harness::Turn::Context.new(player_location: tavern, llm_nuance: stub, game_time: 100)
    ctx.active_scene = Harness::Scene::Active.new(location: tavern, snapshot: Harness::Scene::Assembler.for(location: tavern), narrations: [], extras: [])
    described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "lend me your knife", step: step)
    expect(Item.where("name LIKE ?", "%knife%")).to be_empty
    [ "TAKING STOCK: HANDS", "TAKING STOCK: INNER", "BARGAINS: STRUCK" ].each do |mark|
      judged = JSON.parse(seen.find { |p| p.include?(mark) }.split("INPUT:\n", 2).last)
      expect(judged["this_turn"]).to include(a_string_matching(/\ANothing changed hands: give: Ragnar has nothing to bring out/)), mark
    end
  end

  it "takes stock after speaking: one ladder step, mood refreshed, resolved agenda cleared" do
    active = Harness::Scene::Active.new(
      location: tavern, snapshot: nil, narrations: [],
      internal_state: { barkeep.id => "easy, wiping the bar" },
      agendas: { barkeep.id => "get the stranger to buy a drink" },
      extras: [], entered_at_game_time: 90
    )
    tails = []
    ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
      llm_nuance: StubLLM.new { |full|
        if full.include?("TAKING STOCK")
          tails << full
          { "assessment" => "Tomas hardens toward the freeloader.",
            "disposition" => "colder", "mood" => "polishing the same mug, knuckles white", "agenda" => "resolved",
            "doing" => "turning his back to restack the shelf" }.to_json
        elsif full.include?("WORLD MEMORY")
          { "facts" => [], "people" => [], "places" => [] }.to_json
        else
          { "speak" => true, "dialogue" => { "summary" => "rebuffs", "prose" => "Then we're done here." } }.to_json
        end
      })
    ctx.active_scene = active
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "I'm not buying anything", step: step)

    expect(tails.last).to include("Then we're done here.")   # the eval re-reads the spoken line
    expect(active.disposition_for(barkeep.id)).to eq("guarded")   # neutral → one step colder
    expect(active.state_for(barkeep.id)).to eq("polishing the same mug, knuckles white")
    expect(active.agenda_for(barkeep.id)).to be_nil
    # The activity microbeat lands silently on the scene (perception's read).
    expect(active.doing_for(barkeep.id)).to eq("turning his back to restack the shelf")

    # Next voicing renders the ladder word into the mood line.
    captured = nil
    ctx2 = Harness::Turn::Context.new(player_location: tavern, game_time: 101,
      llm_nuance: StubLLM.new { |full| captured ||= full if voicing?(full); { "speak" => false }.to_json })
    ctx2.active_scene = active
    described_class.new.run(context: ctx2, scene: scene, input: "fine", step: step)
    expect(captured).to include("guarded — polishing the same mug, knuckles white")
  end

  it "surfaces the real nearby places into the voicing call (grounding against invented duplicates)" do
    # The grounding-first lever: the NPC's own surroundings are in its context,
    # so when it reaches for 'the sawmill' the REAL one is right there to name —
    # it can't quietly coin a second.
    town = Location.create!(name: "Ashford")
    tavern.update!(parent_id: town.id)
    Location.create!(name: "the Old Sawmill", parent_id: town.id, description: "the town's lumber mill")
    captured = nil
    ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
      llm_nuance: StubLLM.new { |full| captured = full; { "speak" => false }.to_json })
    ctx.active_scene = Harness::Scene::Active.new(
      location: tavern, snapshot: nil, narrations: [], internal_state: {},
      agendas: {}, extras: [], entered_at_game_time: 0
    )
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "where's the timber milled?", step: step)

    expect(captured).to include("nearby_places")
    expect(captured).to include("the Old Sawmill") # the real mill is in the prompt
    expect(captured).to include("Ashford")         # so is the parent settlement
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
    barkeep_call = seen.find { |s| voicing?(s) && s.include?(%("id": #{barkeep.id},)) }
    ysme_call    = seen.find { |s| voicing?(s) && s.include?(%("id": #{ysme.id},)) }
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
    # Count VOICING calls only — the act judge and the post-turn capture pass (WORLD MEMORY) are orthogonal.
    voicing = polled.select { |p| voicing?(p) }
    expect(voicing.size).to eq(2)
  end

  it "surfaces the venue's for-sale stock with prices — and only when a shop has any" do
    barkeep.update!(subrole: "labourer")   # this is about the venue's own stock, not the barkeep's trade
    polled = []
    ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
      llm_nuance: StubLLM.new { |full| polled << full; { "speak" => true, "dialogue" => { "summary" => "hi", "prose" => "Aye." } }.to_json })
    scene = Harness::Tools::QueryScene.build(ctx)

    described_class.new.run(context: ctx, scene: scene, input: "what do you sell?", step: step("asks about wares"))
    # Assert on the INPUT payload only — the system preamble documents the key.
    payload = polled.find { |p| voicing?(p) }.split("INPUT:").last
    expect(payload).to match(/"wares_here": \[\s*\]/)   # no stock → an explicit empty list, a fact the voice can read

    Item.create!(name: "gleaming saber", subrole: "weapon", location: tavern, properties: { "for_sale" => true })
    Item.create!(name: "old broom", subrole: "tool", location: tavern)  # anchored but not for sale
    polled.clear
    described_class.new.run(context: ctx, scene: scene, input: "what do you sell?", step: step("asks about wares"))

    payload = polled.find { |p| voicing?(p) }.split("INPUT:").last
    expect(payload).to include("wares_here")
    expect(payload).to include("gleaming saber")
    expect(payload).not_to include("old broom")
    expect(payload).to match(/"price": \d+/)
  end

  describe "the contest: kind → binding → consent → dice, before anyone is voiced" do
    def statted!(char, cha: 10)
      char.update!(strength: 10, dexterity: 10, constitution: 10, intelligence: 10, wisdom: 10, charisma: cha)
    end

    # One stub for the turn: the kind judge answers `kind`, a binder `bind`
    # (a hash, or a block called at bind time), consent `consent`; the voice
    # a plain line; the memory judges get empty memory. `seen` collects
    # every prompt, `voiced` the voicing ones.
    def contest_ctx(kind: NO_CONTEST, bind: nil, consent: true, seen: [])
      voiced = []
      stub = StubLLM.new do |full|
        seen << full
        if full.include?(KIND_MARK) then kind.to_json
        elsif full.include?("CONTEST: CONSENT") then { "reasoning" => "judged", "contest" => consent }.to_json
        elsif full.include?("CONTEST: ") then (bind.respond_to?(:call) ? bind.call : bind).to_json
        elsif full.include?("WORLD MEMORY") || full.include?("TAKING STOCK") then { "facts" => [], "people" => [], "places" => [] }.to_json
        elsif full.include?("filter stored facts") then { "relevant" => [] }.to_json
        elsif full.include?(ACT_MARK) then NONE.to_json
        elsif full.include?(CHIME_MARK) then NO_CHIME.to_json
        else
          voiced << full
          { "speak" => true, "dialogue" => { "summary" => "answers", "prose" => "Fine. Ask your questions." } }.to_json
        end
      end
      ctx = Harness::Turn::Context.new(player_location: tavern, llm_nuance: stub, game_time: 100)
      ctx.active_scene = Harness::Scene::Active.new(location: tavern, snapshot: Harness::Scene::Assembler.for(location: tavern), extras: [])
      [ ctx, voiced ]
    end

    def kind(k, with_id, same_as: nil) = { "reasoning" => "judged", "kind" => k, "with_id" => with_id, "same_as" => same_as }
    def run!(ctx, input) = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: input, step: step)
    def prompts(seen, mark) = seen.select { |p| p.include?(mark) }
    def payload_of(prompt)
      body = prompt.split("INPUT:\n", 2).last
      JSON.parse(body[0..body.rindex("}")])
    end
    def won  = Harness::Dice::Outcome.new(result: "success", margin: "clear", critical: false)
    def lost = Harness::Dice::Outcome.new(result: "failure", margin: "clear", critical: false)

    before { statted!(player, cha: 14); statted!(barkeep) }

    it "plain talk: the kind judge sees the player's words, who is here by id with their trade, and the scene's standing verdicts; none means no binder, no consent, no roll, one voicing" do
      expect(Harness::Dice).not_to receive(:check)
      seen = []
      ctx, voiced = contest_ctx(seen: seen)
      outcome = run!(ctx, "where would I find the forge?")
      judged = payload_of(prompts(seen, KIND_MARK).first)
      expect(judged).to eq("player_said" => "where would I find the forge?", "present" => [ { "id" => barkeep.id, "name" => "Tomas", "trade" => "barkeep" } ], "standing" => [])
      expect(prompts(seen, "CONTEST: ").size).to eq(1)
      expect(voiced.size).to eq(1)
      expect(voiced.first).not_to include('"contest"')
      expect(outcome.tool_calls.map { |t| t["name"] }).not_to include("resolve", "contest_standing")
      expect(ctx.active_scene.contest_ledger).to be_blank
    end

    it "a press the target would withhold: consent on the persona and the ask, then the roll, and the target voiced ONCE under the verdict" do
      barkeep.update!(properties: { "personality" => "tight-lipped about the books" })
      allow(Harness::Dice).to receive(:check).and_return(won)
      seen = []
      ctx, voiced = contest_ctx(kind: kind("press", barkeep.id), consent: true, seen: seen)
      outcome = run!(ctx, "press Tomas about the ledger")
      consent = payload_of(prompts(seen, "CONTEST: CONSENT").first)
      expect(consent["you"]).to include("name" => "Tomas", "subrole" => "barkeep", "personality" => "tight-lipped about the books", "disposition" => "neutral", "coins" => 0)
      expect(consent).to include("player_said" => "press Tomas about the ledger", "kind" => "press")
      expect(voiced.size).to eq(1)
      expect(voiced.last).to include('"contest"').and include("Tomas lost — it went the player's way").and include("--- VERDICT ---", '"player_won": true')
      expect(outcome.tool_calls.find { |t| t["name"] == "resolve" }["args"]).to include("action" => "press Tomas", "stat" => "charisma", "target_stat" => "wisdom")
      expect(ctx.active_scene.contest_ledger.keys).to eq([ "#{barkeep.id}:social" ])
      expect(outcome.tool_calls.count { |t| t["name"] == "propose_event" && t.dig("result", "staged") }).to eq(1)
    end

    it "a press the target gives freely is plain talk — no roll, no ledger, one voicing" do
      expect(Harness::Dice).not_to receive(:check)
      ctx, voiced = contest_ctx(kind: kind("press", barkeep.id), consent: false)
      outcome = run!(ctx, "any news from the road?")
      expect(voiced.size).to eq(1)
      expect(voiced.first).not_to include('"contest"')
      expect(outcome.tool_calls.map { |t| t["name"] }).not_to include("resolve", "contest_standing")
      expect(ctx.active_scene.contest_ledger).to be_blank
    end

    it "a contest with no one present bound is plain talk" do
      expect(Harness::Dice).not_to receive(:check)
      seen = []
      ctx, = contest_ctx(kind: kind("press", 999_999), seen: seen)
      outcome = run!(ctx, "press Nelly")
      expect(outcome.tool_calls.find { |t| t["name"] == "resolve" }).to be_nil
      expect(prompts(seen, "CONTEST: CONSENT")).to be_empty
    end

    it "frames a target who WON the press to HOLD, by first name; frames nobody when the roll itself failed" do
      edmund = Npc.create!(name: "Edmund Underhill", subrole: "burner", location: tavern)
      statted!(edmund)
      allow(Harness::Dice).to receive(:check).and_return(lost)
      ctx, voiced = contest_ctx(kind: kind("press", edmund.id))
      run!(ctx, "press Edmund about the mitten")
      target_call = voiced.select { |u| u.include?(%("id": #{edmund.id},)) }.last
      expect(target_call).to include("Edmund won — the player's attempt failed").and include("--- VERDICT ---", "in your favour: persuasion", '"player_won": false')
      expect(target_call).not_to include("Edmund Underhill won")
      expect(target_call).not_to include("yield in your manner")

      allow(Harness::Dice).to receive(:check).and_raise(StandardError, "no dice")
      ctx, voiced = contest_ctx(kind: kind("press", barkeep.id))
      run!(ctx, "press Tomas about the ledger")
      expect(voiced.last).not_to include("--- VERDICT ---")
    end

    it "the same ask again: the kind judge sees the standing verdict numbered and answers same_as; it is re-served as a fact and a recorded event, never rerolled; a won one is framed to yield again" do
      expect(Harness::Dice).to receive(:check).once.and_return(lost)
      seen = []
      runner = described_class.new
      ctx, voiced = contest_ctx(kind: kind("press", barkeep.id), seen: seen)
      runner.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "press Tomas", step: step)
      # second turn: the judge is shown the standing entry and names it
      stub2 = StubLLM.new do |full|
        seen << full
        if full.include?(KIND_MARK) then kind("press", barkeep.id, same_as: 1).to_json
        elsif full.include?("WORLD MEMORY") || full.include?("TAKING STOCK") then { "facts" => [], "people" => [], "places" => [] }.to_json
        elsif full.include?("filter stored facts") then { "relevant" => [] }.to_json
        elsif full.include?(ACT_MARK) then NONE.to_json
        else voiced << full; { "speak" => true, "dialogue" => { "summary" => "holds", "prose" => "I said no." } }.to_json
        end
      end
      ctx.llm_nuance = stub2
      second = runner.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "press Tomas HARDER", step: step)
      expect(payload_of(prompts(seen, KIND_MARK).last)["standing"]).to eq([ { "n" => 1, "with" => "Tomas", "action" => "press Tomas", "verdict" => "Tomas won — the player's attempt failed" } ])
      expect(prompts(seen, "CONTEST: CONSENT").size).to eq(1)   # consent was asked the first time only
      expect(voiced.last).to include("Tomas won — the player's attempt failed; pressed again, the verdict stands")
      expect(voiced.last).not_to include("--- VERDICT ---")
      standing = second.tool_calls.find { |t| t["name"] == "contest_standing" }
      expect(standing["args"]).to include("target_id" => barkeep.id, "action" => "press Tomas")
      expect(standing["result"]).to include("player_won" => false, "repeat" => true)
    end

    it "a won verdict re-served comes with the yield frame again (a fact alone left the target silent, tester run 4 t7)" do
      expect(Harness::Dice).to receive(:check).once.and_return(won)
      runner = described_class.new
      ctx, voiced = contest_ctx(kind: kind("press", barkeep.id))
      runner.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "press Tomas", step: step)
      ctx.llm_nuance = contest_ctx(kind: kind("press", barkeep.id, same_as: 1)).first.llm_nuance
      voiced2 = []
      ctx.llm_nuance = StubLLM.new { |full|
        if full.include?(KIND_MARK) then kind("press", barkeep.id, same_as: 1).to_json
        elsif full.include?("WORLD MEMORY") || full.include?("TAKING STOCK") then { "facts" => [], "people" => [], "places" => [] }.to_json
        elsif full.include?("filter stored facts") then { "relevant" => [] }.to_json
        elsif full.include?(ACT_MARK) then NONE.to_json
        else voiced2 << full; { "speak" => true, "dialogue" => { "summary" => "yields", "prose" => "Fine, again." } }.to_json
        end
      }
      runner.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "press Tomas again", step: step)
      expect(voiced2.last).to include("pressed again, the verdict stands").and include("--- VERDICT ---", "against you")
    end

    describe "haggle" do
      let!(:knife) { Item.create!(name: "bone knife", subrole: "tool", location: tavern, properties: { "tags" => %w[goods tool], "modifiers" => [], "effects" => [], "for_sale" => true, "seller_id" => barkeep.id }) }
      let(:asking) { Harness::Tools::QueryScene.shop_price(knife, tavern) }

      it "the binder sees only the seller's wares with asking prices; a won haggle settles the price at the offer, floored at half the asking — no consent asked, no coins moved" do
        other = Npc.create!(name: "Aelric", subrole: "chandler", location: tavern)
        Item.create!(name: "heavy jar of tallow", subrole: "sundries", location: tavern, properties: { "tags" => %w[goods], "modifiers" => [], "effects" => [], "for_sale" => true, "seller_id" => other.id })
        floor = [ (asking / 2.0).ceil, 1 ].max
        allow(Harness::Dice).to receive(:check).and_return(won)
        seen = []
        ctx, voiced = contest_ctx(kind: kind("haggle", barkeep.id), bind: { "reasoning" => "the knife, one coin", "ware_id" => knife.id, "offer" => 1 }, seen: seen)
        before = player.reload.coins
        outcome = run!(ctx, "One coin for the knife.")
        judged = payload_of(prompts(seen, "CONTEST: HAGGLE").first)
        expect(judged["wares"]).to eq([ { "id" => knife.id, "name" => "bone knife", "asking" => asking } ])
        expect(prompts(seen, "CONTEST: CONSENT")).to be_empty
        settled = [ 1, floor ].max
        expect(knife.reload.properties["haggled_price"]).to eq(settled)
        tomas = voiced.select { |u| u.include?(%("id": #{barkeep.id},)) }
        expect(tomas.size).to eq(1)   # an explicit offer rolls before voicing: one voicing, under the verdict
        expect(tomas.last).to include("--- VERDICT ---", "The dice settled the price", "goes for #{settled} coins")
        names = outcome.tool_calls.map { |t| t["name"] }
        expect(names).to include("haggled")
        expect(names).not_to include("transfer_coins")
        expect(player.reload.coins).to eq(before)
        expect(ctx.active_scene.contest_ledger.keys).to eq([ "#{barkeep.id}:haggle:#{knife.id}" ])
      end

      it "a lost haggle leaves the price where it was and the seller is framed to hold" do
        allow(Harness::Dice).to receive(:check).and_return(lost)
        ctx, voiced = contest_ctx(kind: kind("haggle", barkeep.id), bind: { "reasoning" => "the knife, one coin", "ware_id" => knife.id, "offer" => 1 })
        run!(ctx, "One coin for the knife.")
        expect(knife.reload.properties).not_to have_key("haggled_price")
        expect(voiced.last).to include("in your favour: haggle", "held the price")
      end

      it "a ware off the seller's list, no offer, or an offer at the asking is plain talk — no roll" do
        expect(Harness::Dice).not_to receive(:check)
        ctx, = contest_ctx(kind: kind("haggle", barkeep.id), bind: { "reasoning" => "?", "ware_id" => locket_id = Item.create!(name: "locket", location: tavern).id, "offer" => 1 })
        expect(run!(ctx, "One coin for the locket.").tool_calls.map { |t| t["name"] }).not_to include("resolve", "haggled")
        ctx, = contest_ctx(kind: kind("haggle", barkeep.id), bind: { "reasoning" => "?", "ware_id" => knife.id, "offer" => asking })
        expect(run!(ctx, "I'll pay the full price.").tool_calls.map { |t| t["name"] }).not_to include("resolve", "haggled")
        ctx, = contest_ctx(kind: kind("haggle", barkeep.id), bind: { "reasoning" => "?", "ware_id" => knife.id, "offer" => nil })
        expect(run!(ctx, "Cheaper?").tool_calls.map { |t| t["name"] }).not_to include("resolve", "haggled")
        expect(locket_id).to be_a(Integer)
      end
    end

    describe "games and wagers" do
      def wager(faculty, stake_coins: nil, stake_item_id: nil, against_coins: nil, against_item_id: nil)
        { "reasoning" => "bound", "faculty" => faculty, "stake_coins" => stake_coins, "stake_item_id" => stake_item_id, "against_coins" => against_coins, "against_item_id" => against_item_id }
      end

      it "a wager: the binder sees the player's things and the seller's wares, binds the faculty and both stakes; consent, then the roll settles the stakes — nothing owed; the same game again is the standing verdict" do
        player.update!(coins: 5); barkeep.update!(coins: 3)
        Item.create!(name: "dark ale", subrole: "drink", location: tavern, properties: { "tags" => %w[provision drink], "modifiers" => [], "effects" => [], "for_sale" => true, "seller_id" => barkeep.id })
        allow(Harness::Dice).to receive(:check).and_return(won)
        seen = []
        ctx, voiced = contest_ctx(kind: kind("wager", barkeep.id), bind: wager("dexterity", stake_coins: 2, against_coins: 2), seen: seen)
        outcome = run!(ctx, "Two coins on the throw, high roll wins.")
        judged = payload_of(prompts(seen, "CONTEST: WAGER").first)
        expect(judged["wares"].map { |w| w["name"] }).to eq([ "dark ale" ])
        expect(judged).to have_key("carried")
        expect(payload_of(prompts(seen, "CONTEST: CONSENT").first)).to include("kind" => "wager", "terms" => "2 coins against 2 coins, a game of dexterity")
        expect([ player.reload.coins, barkeep.reload.coins ]).to eq([ 7, 1 ])
        expect(outcome.tool_calls.find { |t| t["name"] == "transfer_coins" }["result"]).to include("from_id" => barkeep.id, "to_id" => player.id, "amount" => 2)
        expect(outcome.tool_calls.find { |t| t["name"] == "resolve" }["args"]).to include("action" => "wager with Tomas: 2 coins against 2 coins", "stat" => "dexterity", "target_stat" => "dexterity")
        expect(voiced.last).to include("The dice settled the wager", "Tomas lost the wager — 2 coins went to the player")
        expect(ctx.active_scene.contest_ledger.keys).to eq([ "#{barkeep.id}:dexterity" ])
        expect(Obligation.count).to eq(0)

        ctx.llm_nuance = contest_ctx(kind: kind("wager", barkeep.id, same_as: 1), bind: wager("dexterity", stake_coins: 2, against_coins: 2)).first.llm_nuance
        second = run!(ctx, "Again, two coins.")
        expect(second.tool_calls.map { |t| t["name"] }).to include("contest_standing")
        expect(second.tool_calls.map { |t| t["name"] }).not_to include("transfer_coins", "resolve")
        expect([ player.reload.coins, barkeep.reload.coins ]).to eq([ 7, 1 ])
      end

      it "a bet placed on a game already played for nothing is a new game when the judge says so (items run 9 t11–t14)" do
        player.update!(coins: 5); barkeep.update!(coins: 3)
        allow(Harness::Dice).to receive(:check).and_return(lost)
        ctx, = contest_ctx(kind: kind("game", barkeep.id), bind: { "reasoning" => "arm-wrestle", "faculty" => "strength" })
        run!(ctx, "Anyone fancy an arm-wrestle?")
        expect(ctx.active_scene.contest_for("#{barkeep.id}:strength")).to include("player_won" => false)
        allow(Harness::Dice).to receive(:check).and_return(won)
        ctx.llm_nuance = contest_ctx(kind: kind("wager", barkeep.id), bind: wager("strength", stake_coins: 3, against_coins: 2)).first.llm_nuance
        outcome = run!(ctx, "Make it real: 3 coins against 2 of yours.")
        expect(outcome.tool_calls.map { |t| t["name"] }).to include("resolve", "transfer_coins")
        expect([ player.reload.coins, barkeep.reload.coins ]).to eq([ 7, 1 ])
        expect(ctx.active_scene.contest_for("#{barkeep.id}:strength")).to include("wager" => true, "player_won" => true)
      end

      it "a lost item wager lands the thing on the winner's table, for sale under their name" do
        player.update!(coins: 1); barkeep.update!(coins: 3)
        mead = Item.create!(name: "dark mead", subrole: "drink", character: player, properties: { "tags" => %w[provision drink], "modifiers" => [], "effects" => [] })
        allow(Harness::Dice).to receive(:check).and_return(lost)
        ctx, voiced = contest_ctx(kind: kind("wager", barkeep.id), bind: wager("dexterity", stake_item_id: mead.id, against_coins: 1))
        outcome = run!(ctx, "My mead against a coin, high roll.")
        expect(mead.reload.character_id).to be_nil
        expect(mead.location_id).to eq(tavern.id)
        expect(mead.properties).to include("for_sale" => true, "seller_id" => barkeep.id)
        expect(Harness::Turn::Parts.render_call(outcome.tool_calls.find { |t| t["name"] == "wager_stake" }, ctx, nil)[:text]).to eq("The dark mead goes to Tomas's table.")
        expect(voiced.last).to include("Tomas won the wager — the dark mead went to Tomas")
        expect([ player.reload.coins, barkeep.reload.coins ]).to eq([ 1, 3 ])
      end

      it "a wager binds both sides or none: beyond the means, not on their table, or a side unnamed voids it — no consent asked, no roll, a receipt, the fact in the target's payload" do
        player.update!(coins: 1); barkeep.update!(coins: 3)
        expect(Harness::Dice).not_to receive(:check)
        cases = {
          wager("dexterity", stake_coins: 10, against_coins: 2)          => [ "you don't have 10 coins to stake", "Hero doesn't have 10 coins to stake" ],
          wager("dexterity", stake_coins: 1, against_item_id: 999_999)   => [ "Tomas has no such thing on the table to stake" ] * 2,
          wager("dexterity", stake_coins: 1)                             => [ "nothing of Tomas's was staked" ] * 2,
          wager("dexterity", stake_item_id: 999_999, against_coins: 1)   => [ "you carry no such thing to stake", "Hero carries no such thing to stake" ]
        }
        cases.each do |bound, (reason, told)|
          seen = []
          ctx, voiced = contest_ctx(kind: kind("wager", barkeep.id), bind: bound, seen: seen)
          outcome = run!(ctx, "A bet, then.")
          names = outcome.tool_calls.map { |t| t["name"] }
          expect(names).to include("wager_void")
          expect(names).not_to include("resolve", "transfer_coins", "wager_stake")
          expect(prompts(seen, "CONTEST: CONSENT")).to be_empty
          void = outcome.tool_calls.find { |t| t["name"] == "wager_void" }
          expect(Harness::Turn::Parts.render_call(void, ctx, nil)[:text]).to eq("No wager — #{reason}.")
          expect(voiced.last).to include("no wager was set — #{told}")
          expect(voiced.last).not_to include("--- VERDICT ---")
          expect(ctx.active_scene.contest_ledger).to be_blank
        end
        expect([ player.reload.coins, barkeep.reload.coins ]).to eq([ 1, 3 ])
      end

      it "a wager with nothing staked on either side is a turn of phrase: bound as the press it carries" do
        allow(Harness::Dice).to receive(:check).and_return(won)
        seen = []
        ctx, = contest_ctx(kind: kind("wager", barkeep.id), bind: wager("chance"), seen: seen)
        outcome = run!(ctx, "You've a knife on you somewhere, I'd wager. Lend it here.")
        expect(outcome.tool_calls.map { |t| t["name"] }).not_to include("wager_void", "contest_chance")
        expect(outcome.tool_calls.find { |t| t["name"] == "resolve" }["args"]).to include("action" => "press Tomas", "stat" => "charisma")
        expect(payload_of(prompts(seen, "CONTEST: CONSENT").first)["kind"]).to eq("press")
        expect(ctx.active_scene.contest_ledger.keys).to eq([ "#{barkeep.id}:social" ])
      end

      it "a game the target declines: no roll, a receipt that they won't play, the fact in their payload, nothing moved" do
        player.update!(coins: 5); barkeep.update!(coins: 3)
        expect(Harness::Dice).not_to receive(:check)
        ctx, voiced = contest_ctx(kind: kind("wager", barkeep.id), bind: wager("dexterity", stake_coins: 2, against_coins: 2), consent: false)
        outcome = run!(ctx, "Two coins on the throw?")
        void = outcome.tool_calls.find { |t| t["name"] == "wager_void" }
        expect(Harness::Turn::Parts.render_call(void, ctx, nil)[:text]).to eq("No wager — Tomas won't play.")
        expect(voiced.last).to include("Tomas declined the game — nothing was played")
        expect(voiced.last).not_to include("--- VERDICT ---")
        expect([ player.reload.coins, barkeep.reload.coins ]).to eq([ 5, 3 ])
        expect(ctx.active_scene.contest_ledger).to be_blank
      end

      it "a game of skill rolls the same faculty on both sides, keyed by it" do
        allow(Harness::Dice).to receive(:check).and_return(won)
        ctx, voiced = contest_ctx(kind: kind("game", barkeep.id), bind: { "reasoning" => "knuckle-bones", "faculty" => "dexterity" })
        outcome = run!(ctx, "beat Tomas at knuckle-bones")
        record = outcome.tool_calls.find { |t| t["name"] == "resolve" }
        expect(record["args"]).to include("stat" => "dexterity", "target_stat" => "dexterity", "action" => "a game of dexterity with Tomas")
        expect(ctx.active_scene.contest_ledger.keys).to eq([ "#{barkeep.id}:dexterity" ])
        expect(voiced.first).to include("dexterity contest")
      end

      it "a game of chance is the engine's own fair flip on the turn's dice — no stat roll, recorded and bracketed like one" do
        expect(Harness::Dice).not_to receive(:check)
        allow(Harness::RNG.current).to receive(:rand).with(2).and_return(1)
        ctx, voiced = contest_ctx(kind: kind("wager", barkeep.id), bind: wager("chance", stake_coins: 1, against_coins: 1))
        player.update!(coins: 5); barkeep.update!(coins: 3)
        outcome = run!(ctx, "Call it — heads or tails, a coin on it.")
        flip = outcome.tool_calls.find { |t| t["name"] == "contest_chance" }
        expect(flip["result"]).to include("outcome" => "failure", "stat" => "chance")
        expect(Harness::Turn::Parts.render_call(flip, ctx, nil)[:text]).to eq("[wager with Tomas: 1 coins against 1 coins — Chance: failure]")
        expect(outcome.tool_calls.map { |t| t["name"] }).not_to include("resolve")
        expect([ player.reload.coins, barkeep.reload.coins ]).to eq([ 4, 4 ])
        expect(voiced.last).to include('"kind": "wager"', "Tomas won the wager — 1 coins went to Tomas")
        expect(ctx.active_scene.contest_ledger.keys).to eq([ "#{barkeep.id}:chance" ])
      end
    end

    describe "a press with an ability" do
      it "the binder is shown only the player's social powers and binds the one invoked: cast with its modifier, a use spent, the effect injected, keyed by the ability" do
        player.update!(abilities: [
          { "id" => "charm_word", "name" => "Charm Word", "description" => "The target finds the sorcerer plausible for one critical beat.",
            "effect_kind" => "control", "stat" => "charisma", "opposed_by" => "wisdom", "uses_per_rest" => 2, "uses_remaining" => 2, "roll_modifier" => 3 },
          { "id" => "arcane_bolt", "name" => "Arcane Bolt", "description" => "A thin streak of pale force.",
            "effect_kind" => "damage", "stat" => "intelligence", "damage_dice" => "1d6", "uses_per_rest" => 4, "uses_remaining" => 4 }
        ])
        expect(Harness::Dice).to receive(:check).with(hash_including(roll_modifier: 3)).and_return(won)
        seen = []
        ctx, voiced = contest_ctx(kind: kind("press", barkeep.id), bind: { "reasoning" => "the charm", "ability_id" => "charm_word" }, seen: seen)
        run!(ctx, "quietly cast charm word on Tomas")
        expect(payload_of(prompts(seen, "CONTEST: PRESS").first)["abilities"]).to eq([ { "id" => "charm_word", "name" => "Charm Word" } ])
        expect(voiced.first).to include("plausible for one critical beat")
        expect(player.reload.abilities.first["uses_remaining"]).to eq(1)
        expect(ctx.active_scene.contest_ledger.keys).to eq([ "#{barkeep.id}:charm_word" ])
      end

      it "with no social power to bind, the binder is not asked and the press rolls as persuasion — a damage power never fires from a pitch" do
        player.update!(abilities: [ { "id" => "arcane_bolt", "name" => "Arcane Bolt", "description" => "A thin streak of pale force.",
                                      "effect_kind" => "damage", "stat" => "intelligence", "damage_dice" => "1d6", "uses_per_rest" => 4, "uses_remaining" => 4 } ])
        allow(Harness::Dice).to receive(:check).and_return(won)
        seen = []
        ctx, voiced = contest_ctx(kind: kind("press", barkeep.id), seen: seen)
        outcome = run!(ctx, "attack magic, want a cut?")
        expect(prompts(seen, "CONTEST: PRESS")).to be_empty
        record = outcome.tool_calls.find { |t| t["name"] == "resolve" }
        expect(record["args"]).to include("stat" => "charisma")
        expect(record["args"]).not_to have_key("ability_name")
        expect(barkeep.reload.current_hp).to eq(barkeep.max_hp)
        expect(player.reload.abilities.first["uses_remaining"]).to eq(4)
        expect(voiced.first).not_to include("pale force")
      end
    end

    it "the six contest grammars: reasoning first, every field required, every field the prompts name in the grammar; zero temperature, thinking off" do
      seen = []
      ctx, = contest_ctx(seen: seen)
      run!(ctx, "hello")
      llm = ctx.llm_nuance
      i = llm.system_calls.index { |sys| sys.include?(KIND_MARK) }
      expect(llm.sampling_calls[i]).to eq(temperature: 0, thinking: false, max_tokens: nil)
      c = described_class
      pairs = { c::CONTEST_KIND_PATH => c::CONTEST_KIND_SCHEMA, c::CONTEST_CONSENT_PATH => c::CONTEST_CONSENT_SCHEMA }
      c::CONTEST_BIND_PATHS.each { |k, path| pairs[path] = c::CONTEST_BIND_SCHEMAS[k] }
      pairs.each do |path, schema|
        expect(schema["properties"].keys.first).to eq("reasoning")
        expect(schema["required"]).to eq(schema["properties"].keys)
        named = File.read(path).split("Output:", 2).last.scan(/"(\w+)":/).flatten.uniq
        expect(named.sort).to eq(schema["properties"].keys.sort), "#{File.basename(path)} names #{named.inspect}"
      end
    end
  end

  describe "knowledge recall" do
    it "recalls a gate-approved fact into the speaker's voicing context" do
      Knowledge.create!(content: "The salt tithe was repealed last winter.", location_id: tavern.id, current: true, game_time: 0)
      voicing_prompt = nil
      ctx = context_with do |full|
        if full.include?("filter stored facts")   # the relevance gate (synthetic ids: fact is candidate #1)
          { "relevant" => [ 1 ] }.to_json
        elsif (full.include?("WORLD MEMORY") || full.include?("TAKING STOCK"))        # capture (fires on grounded turns too)
          { "facts" => [] }.to_json
        else                                       # the barkeep's voicing
          voicing_prompt = full
          { "speak" => true, "dialogue" => { "summary" => "answers", "prose" => "Aye, repealed last winter." } }.to_json
        end
      end
      scene = Harness::Tools::QueryScene.build(ctx)

      described_class.new.run(context: ctx, scene: scene, input: "is there still a salt tithe?", step: step("ask about the tithe"))
      expect(voicing_prompt).to include("The salt tithe was repealed last winter.")
    end

    it "feeds the NPC's own memories into the SAME relevance gate as facts (fusion)" do
      Knowledge.create!(content: "The salt tithe was repealed last winter.", location_id: tavern.id, current: true, game_time: 0)
      Harness::Event::ForwardAppender.append(
        game_time: 0, scope: "personal", location: tavern,
        details: { "narrative" => { "trigger" => "saw", "details" => "The ferryman drowned at the crossing." } },
        participants: [ { character: barkeep, role: "subject" } ]
      )
      # A text-less mechanical log (resolve-shaped details) must NOT reach
      # the gate as a blank candidate.
      Harness::Event::ForwardAppender.append(
        game_time: 5, scope: "personal", location: tavern,
        details: { "action" => "resolve", "outcome" => "success" },
        participants: [ { character: barkeep, role: "actor" } ]
      )
      gate_prompt = nil
      ctx = context_with do |full|
        if full.include?("filter stored facts")
          gate_prompt = full
          { "relevant" => [] }.to_json
        else
          { "speak" => true, "dialogue" => { "summary" => "x", "prose" => "Hm." } }.to_json
        end
      end
      scene = Harness::Tools::QueryScene.build(ctx)

      described_class.new.run(context: ctx, scene: scene, input: "what happened at the crossing?", step: step)
      expect(gate_prompt).to include("The salt tithe was repealed")  # the fact
      expect(gate_prompt).to include("ferryman drowned")             # the memory — both through one gate
      expect(gate_prompt).not_to include('"text": ""')               # the blank mechanical log stayed out
    end

    it "injects nothing when the gate rejects every candidate" do
      Knowledge.create!(content: "The salt tithe was repealed last winter.", location_id: tavern.id, current: true, game_time: 0)
      voicing_prompt = nil
      ctx = context_with do |full|
        if full.include?("filter stored facts")
          { "relevant" => [] }.to_json
        else
          voicing_prompt = full
          { "speak" => true, "dialogue" => { "summary" => "shrugs", "prose" => "Couldn't say." } }.to_json
        end
      end
      scene = Harness::Tools::QueryScene.build(ctx)

      described_class.new.run(context: ctx, scene: scene, input: "is there still a salt tithe?", step: step)
      expect(voicing_prompt).not_to include("The salt tithe was repealed")
    end

    it "does not recall (no gate call) when the NPC has no candidates at all" do
      gate_called = false
      ctx = context_with do |full|
        gate_called = true if full.include?("filter stored facts")
        { "speak" => true, "dialogue" => { "summary" => "greets", "prose" => "What'll it be?" } }.to_json
      end
      scene = Harness::Tools::QueryScene.build(ctx)

      described_class.new.run(context: ctx, scene: scene, input: "anything worth knowing?", step: step)
      expect(gate_called).to be(false)
    end
  end

  describe "silent conversation turn (the narrator-vacuum marker)" do
    it "appends a conversation_silence marker when every polled character declines" do
      ctx = context_with { { "speak" => false }.to_json }
      scene = Harness::Tools::QueryScene.build(ctx)

      out = described_class.new.run(context: ctx, scene: scene, input: "anything to say?", step: step("chat"))
      silence = out.tool_calls.find { |t| t["name"] == "conversation_silence" }
      expect(silence).to be_present
      expect(silence.dig("result", "nobody_spoke")).to be(true)
    end

    it "appends NO marker when someone actually spoke" do
      ctx = context_with do |full|
        next({ "facts" => [] }.to_json) if (full.include?("SECOND PASS: WORLD MEMORY") || full.include?("TAKING STOCK"))
        { "speak" => true, "dialogue" => { "summary" => "s", "prose" => "Aye, what'll it be?" } }.to_json
      end
      scene = Harness::Tools::QueryScene.build(ctx)

      out = described_class.new.run(context: ctx, scene: scene, input: "hello barkeep", step: step)
      expect(out.tool_calls.map { |t| t["name"] }).not_to include("conversation_silence")
    end
  end

  describe "parrot gauge (log only — a repeated line is kept, never suppressed)" do
    def active_scene_for(ctx)
      Harness::Scene::Active.new(
        location: tavern, snapshot: nil, narrations: [], internal_state: {}, agendas: {},
        extras: [], entered_at_game_time: 0
      ).tap { |a| ctx.active_scene = a }
    end

    def active_with(lines)
      Harness::Scene::Active.new(
        location: tavern, snapshot: nil, narrations: [], internal_state: {}, agendas: {},
        extras: [], entered_at_game_time: 0
      ).tap { |a| lines.each { |id, l| a.record_line!(id, l) } }
    end

    # The suppressor this used to be answered a re-ask with "No one reacts."
    # (2026-09-12); the shapes it caught are fixed at their source. The
    # detector stays as a gauge that names whose line was reproduced.
    it "keeps a verbatim re-emit of the speaker's previous line" do
      line = "Aye, the salt tithe was repealed last winter, and good riddance to it."
      ctx = context_with do |full|
        next({ "facts" => [] }.to_json) if (full.include?("SECOND PASS: WORLD MEMORY") || full.include?("TAKING STOCK"))
        { "speak" => true, "dialogue" => { "summary" => "gossips", "prose" => line } }.to_json
      end
      active_scene_for(ctx)
      scene = Harness::Tools::QueryScene.build(ctx)

      first  = described_class.new.run(context: ctx, scene: scene, input: "any news?", step: step)
      second = described_class.new.run(context: ctx, scene: scene, input: "tell me more", step: step)
      expect(first.tool_calls.count  { |t| t["name"] == "propose_event" }).to eq(1)
      expect(second.tool_calls.count { |t| t["name"] == "propose_event" }).to eq(1)
    end

    it "keeps a cross-speaker copy (the Sten case) — the chorus is fixed where it is fed, not by an output filter" do
      Npc.create!(name: "Ragnar", subrole: "innkeeper", location: tavern)
      chunk    = "The Reeve is haggling for timber rights again. Not exactly a secret, just business, drink up friend."
      tomas_id = Npc.find_by!(name: "Tomas").id
      turn     = 0
      ctx = context_with do |full|
        next({ "facts" => [] }.to_json) if (full.include?("SECOND PASS: WORLD MEMORY") || full.include?("TAKING STOCK"))
        # Route on the speaker's OWN block: the room list names Tomas in Ragnar's call too.
        tomas = full.include?("\"you\": {\n    \"id\": #{tomas_id},")
        if turn == 1
          tomas ? { "speak" => true, "dialogue" => { "summary" => "gossips", "prose" => "Tomas leans on the bar. \"#{chunk}\"" } }.to_json : { "speak" => false }.to_json
        else
          tomas ? { "speak" => false }.to_json : { "speak" => true, "dialogue" => { "summary" => "echoes", "prose" => "Ragnar crosses his arms. \"#{chunk}\"" } }.to_json
        end
      end
      active_scene_for(ctx)
      scene = Harness::Tools::QueryScene.build(ctx)

      turn = 1
      first = described_class.new.run(context: ctx, scene: scene, input: "any news?", step: step)
      expect(first.tool_calls.count { |t| t["name"] == "propose_event" }).to eq(1)
      turn = 2
      second = described_class.new.run(context: ctx, scene: scene, input: "timber rights?", step: step)
      expect(second.tool_calls.count { |t| t["name"] == "propose_event" }).to eq(1)
    end

    it "detects the shapes it logs: quoted speech lifted from another speaker, a whole-line run, an exact own repeat" do
      runner = described_class.new
      active = active_with(
        1 => "Tomas watches the kiln. 'Kiln’s burning slow today — steady heat, no flare. Good for even char.'",
        2 => "His grin doesn't waver, though he lowers his voice just enough to cut through the cold stare. He leans in close and names the Flats."
      )
      expect(runner.send(:parroted_line_owner, active, "Swithun plucks a string. ‘I wrote a verse: steady heat, no flare, good for even char.’")).to eq(1)
      expect(runner.send(:parroted_line_owner, active, "His grin doesn't waver, though he lowers his voice just enough to cut through the cold stare. He leans in close and names the docks instead.")).to eq(2)
      expect(runner.send(:parroted_line_owner, active, "Tomas watches the kiln. 'Kiln’s burning slow today — steady heat, no flare. Good for even char.'")).to eq(1)
    end

    it "does not count a repeated BEAT around new words, nor a fresh short answer" do
      runner = described_class.new
      active = active_with(1 => "Tomas wipes soot from his brow and meets your gaze. \"I need ore hauled up the ridge. Two silver.\"")
      expect(runner.send(:parroted_line_owner, active, "Tomas wipes soot from his brow and meets your gaze. \"Last man? Went up the ridge and never came down.\"")).to be_nil
      expect(runner.send(:parroted_line_owner, active, "Tomas shrugs. \"Couldn't say.\"")).to be_nil
    end
  end
  describe "venue exposure" do
    it "tells every voicing call WHERE the conversation is (the Common Room leak fix)" do
      voicing_prompt = nil
      ctx = context_with do |full|
        voicing_prompt = full unless (full.include?("WORLD MEMORY") || full.include?("TAKING STOCK")) || full.include?("filter stored facts")
        { "speak" => true, "dialogue" => { "summary" => "hi", "prose" => "Well met." } }.to_json
      end
      scene = Harness::Tools::QueryScene.build(ctx)

      described_class.new.run(context: ctx, scene: scene, input: "hello", step: step)
      expect(voicing_prompt).to include("\"location\"")
      expect(voicing_prompt).to include("\"name\": \"The Drowned Rat\"")
    end

    it "includes the parent place for a sublocation venue" do
      city = Location.create!(name: "Saltmere")
      tavern.update!(parent_id: city.id)
      voicing_prompt = nil
      ctx = context_with do |full|
        voicing_prompt = full unless (full.include?("WORLD MEMORY") || full.include?("TAKING STOCK")) || full.include?("filter stored facts")
        { "speak" => true, "dialogue" => { "summary" => "hi", "prose" => "Well met." } }.to_json
      end
      scene = Harness::Tools::QueryScene.build(ctx)

      described_class.new.run(context: ctx, scene: scene, input: "hello", step: step)
      expect(voicing_prompt).to include("\"part_of\": \"Saltmere\"")
    end
  end

  describe "semantic event recall (both stores ranked by topic)" do
    # StubLLM + a deterministic embedder: anything mentioning "mill" points
    # one way, everything else points the other.
    class EmbeddingStubLLM < StubLLM
      def embed(input)
        texts = input.is_a?(Array) ? input : [ input ]
        vecs  = texts.map { |t| t.to_s.downcase.include?("mill") ? [ 1.0, 0.0 ] : [ 0.0, 1.0 ] }
        input.is_a?(Array) ? vecs : vecs.first
      end
    end

    def event_for(char, text, at:)
      ev = Event.create!(game_time: at, scope: "personal", location: tavern,
                         details: { "narrative" => { "trigger" => "memory", "details" => text } })
      EventParticipant.create!(event: ev, character: char, role: "actor")
      ev
    end

    it "surfaces an on-topic memory from beyond the recency window and backfills its embedding" do
      Knowledge.create!(content: "The town mill ground to a halt years ago.", location_id: tavern.id, current: true, game_time: 0)
      old_mill = event_for(barkeep, "The mill wheel shattered in the spring flood.", at: 50)
      10.times { |i| event_for(barkeep, "Uneventful shift number #{i}.", at: 1_000 + i) }

      voicing_prompt = nil
      llm = EmbeddingStubLLM.new do |full|
        if (full.include?("SECOND PASS: WORLD MEMORY") || full.include?("TAKING STOCK"))
          { "facts" => [], "people" => [], "places" => [] }.to_json
        elsif full.include?("filter stored facts")
          # ONE ranked pool: the mill fact and mill memory tie at the top in
          # either order — approve both
          { "relevant" => [ 1, 2 ] }.to_json
        elsif full.include?(ACT_MARK)
          NONE.to_json
        else
          voicing_prompt = full
          { "speak" => true, "dialogue" => { "summary" => "recalls", "prose" => "Tomas sighs." } }.to_json
        end
      end
      ctx = Harness::Turn::Context.new(player_location: tavern, llm_nuance: llm, game_time: 2_000)
      scene = Harness::Tools::QueryScene.build(ctx)

      described_class.new.run(context: ctx, scene: scene, input: "what happened to the mill?", step: step)

      # The old memory beat 10 newer noise events into the voicing payload…
      expect(voicing_prompt).to include("The mill wheel shattered in the spring flood.")
      # …stamped with relative time computed from game_time (50 → 2000 ≈ a day)…
      expect(voicing_prompt).to include("(yesterday)")
      # …and its vector was persisted for next time.
      expect(old_mill.reload.embedding).to be_present
    end
  end

  describe "voicing grammar (schema + the empty-prose break-off)" do
    it "lists the required-but-conditional subrole BEFORE the keys every emit carries — property order is grammar on the hosted compiler" do
      keys = Harness::Runners::Conversation::VOICING_SCHEMA["properties"].keys
      expect(keys.last).to eq("doing")   # the key the model writes last; the brace must be legal after it
    end

    it "passes VOICING_SCHEMA on the voicing call" do
      ctx = context_with do
        { "speak" => false }.to_json
      end
      scene = Harness::Tools::QueryScene.build(ctx)
      described_class.new.run(context: ctx, scene: scene, input: "hello barkeep", step: step)
      expect(ctx.llm_nuance.schema_calls.compact).to include(described_class::VOICING_SCHEMA)
    end

    it "treats explicit empty prose as a break-off: no bounce, no staged line, silence marked" do
      voicing_calls = 0
      ctx = context_with do |full|
        next({ "relevant" => [] }.to_json) if full.include?("filter stored facts")
        voicing_calls += 1
        { "thought" => "Tomas thinks better of it.", "speak" => true,
          "dialogue" => { "summary" => "breaks off", "prose" => "" } }.to_json
      end
      scene = Harness::Tools::QueryScene.build(ctx)
      outcome = described_class.new.run(context: ctx, scene: scene, input: "hello barkeep", step: step)
      expect(voicing_calls).to eq(1)                                            # no retry burned
      expect(outcome.tool_calls.find { |t| t["name"] == "propose_event" }).to be_nil
      expect(outcome.tool_calls.find { |t| t["name"] == "conversation_silence" }).to be_present
    end

    it "still bounces speak-true with dialogue null (format loss keeps its retry)" do
      voicing_calls = 0
      ctx = context_with do |full|
        next({ "facts" => [], "people" => [], "places" => [] }.to_json) if full.include?("WORLD MEMORY") || full.include?("TAKING STOCK")
        next({ "relevant" => [] }.to_json) if full.include?("filter stored facts")
        voicing_calls += 1
        if full.include?("--- RETRY ---")
          { "thought" => "t", "speak" => true, "dialogue" => { "summary" => "answers", "prose" => "Aye, what of it?" } }.to_json
        else
          { "thought" => "t", "speak" => true, "dialogue" => nil }.to_json
        end
      end
      scene = Harness::Tools::QueryScene.build(ctx)
      outcome = described_class.new.run(context: ctx, scene: scene, input: "hello barkeep", step: step)
      expect(voicing_calls).to eq(2)
      say = outcome.tool_calls.find { |t| t["name"] == "propose_event" }
      expect(say.dig("args", "details")).to eq("Aye, what of it?")
    end
  end

  describe "recall gating (likely speakers only)" do
    # recall() is the per-NPC gate door; spy on it to see who pays for it.
    def run_spying(input, with_id)
      runner = described_class.new
      recalled = []
      allow(runner).to receive(:recall).and_wrap_original do |orig, ctx, npc_row, topic|
        recalled << npc_row.name
        orig.call(ctx, npc_row, topic)
      end
      ctx = context_with do |full|
        if full.include?("filter stored facts")
          { "relevant" => [] }.to_json
        else
          { "speak" => false }.to_json
        end
      end
      scene = Harness::Tools::QueryScene.build(ctx)
      runner.run(context: ctx, scene: scene, input: input, step: (with_id ? step_to(with_id) : step("asks the room")))
      recalled
    end

    it "skips the recall gate for un-addressed bystanders when someone is named" do
      Npc.create!(name: "Maud", subrole: "fishwife", location: tavern)
      recalled = run_spying("Tomas, what news from the docks?", barkeep.id)
      expect(recalled).to eq([ "Tomas" ])
    end

    it "keeps recall for everyone on an open-mic input (nobody named)" do
      Npc.create!(name: "Maud", subrole: "fishwife", location: tavern)
      recalled = run_spying("anyone hear anything strange lately?", nil)
      expect(recalled).to contain_exactly("Tomas", "Maud")
    end
  end

  describe "knowledge reflection (per-speaker capture)" do
    it "writes a fact the speaker's reflection reports" do
      ctx = context_with do |full|
        if (full.include?("SECOND PASS: WORLD MEMORY") || full.include?("TAKING STOCK"))   # the reflection tail
          { "facts" => [ { "content" => "The salt tithe was repealed last winter.", "subrole" => nil, "scope" => "local", "min_int" => nil } ] }.to_json
        elsif full.include?("filter stored facts")      # relevance gate
          { "relevant" => [] }.to_json
        else                                            # the barkeep's voicing call
          { "speak" => true, "dialogue" => { "summary" => "gossips", "prose" => "They say the salt tithe was repealed last winter." } }.to_json
        end
      end
      scene = Harness::Tools::QueryScene.build(ctx)

      expect {
        described_class.new.run(context: ctx, scene: scene, input: "any news?", step: step)
      }.to change(Knowledge, :count).by(1)
      expect(Knowledge.last.content).to match(/salt tithe/)
    end

    it "bounces a DIALOGUE-schema reflection once and ingests the corrected answer" do
      reflection_calls = 0
      ctx = context_with do |full|
        if full.include?("--- RETRY ---")               # the correction bounce
          expect(full).to include("answered in DIALOGUE schema")
          { "facts" => [ { "content" => "Eli works the crab pots by the shed.", "concerns" => [], "scope" => "local" } ] }.to_json
        elsif (full.include?("SECOND PASS: WORLD MEMORY") || full.include?("TAKING STOCK")) # schema collision: model re-voiced
          reflection_calls += 1
          { "thought" => "…", "speak" => true, "dialogue" => { "summary" => "repeats", "prose" => "As I said." } }.to_json
        elsif full.include?("filter stored facts")
          { "relevant" => [] }.to_json
        else
          { "speak" => true, "dialogue" => { "summary" => "gossips", "prose" => "There's a lad named Eli by the shed." } }.to_json
        end
      end
      scene = Harness::Tools::QueryScene.build(ctx)

      expect {
        described_class.new.run(context: ctx, scene: scene, input: "any news?", step: step)
      }.to change(Knowledge, :count).by(1)
      expect(Knowledge.last.content).to match(/crab pots/)
      expect(reflection_calls).to eq(2)   # two judges (claims, bargains), one bounce each
    end

    it "bounces a MALFORMED-JSON reflection once instead of raising past the retry (the Bodil charm-meet drop)" do
      ctx = context_with do |full|
        if full.include?("BARGAINS: STRUCK") && full.include?("--- RETRY ---")   # the correction bounce
          expect(full).to include("unparseable")
          { "reasoning" => "the shed at dusk, taken", "struck" => true, "proposed_by" => "player", "accepted_by" => "you" }.to_json
        elsif full.include?("BARGAINS: TERMS")
          { "reasoning" => "Tomas to be at the shed at dusk", "due" => "at dusk", "where" => nil,
            "sides" => [ { "who" => "you", "kind" => "meet", "amount" => nil, "terms" => "Meet at the shed at dusk." } ] }.to_json
        elsif (full.include?("SECOND PASS: WORLD MEMORY") || full.include?("TAKING STOCK")) # truncated garbage
          "{\"facts\": [\n{"
        elsif full.include?("filter stored facts")
          { "relevant" => [] }.to_json
        else
          { "speak" => true, "dialogue" => { "summary" => "agrees", "prose" => "Fine. The shed, at dusk." } }.to_json
        end
      end
      scene = Harness::Tools::QueryScene.build(ctx)

      expect {
        described_class.new.run(context: ctx, scene: scene, input: "meet me at the shed at dusk?", step: step)
      }.to change(Obligation, :count).by(1)
      expect(Obligation.last.kind).to eq("meet")
    end

    it "drops the claims when the reflection bounce also fails (no infinite loop)" do
      ctx = context_with do |full|
        if (full.include?("SECOND PASS: WORLD MEMORY") || full.include?("TAKING STOCK"))   # collision on BOTH attempts (retry contains this too)
          { "thought" => "…", "speak" => true, "dialogue" => { "summary" => "repeats", "prose" => "As I said." } }.to_json
        elsif full.include?("filter stored facts")
          { "relevant" => [] }.to_json
        else
          { "speak" => true, "dialogue" => { "summary" => "gossips", "prose" => "There's a lad named Eli by the shed." } }.to_json
        end
      end
      scene = Harness::Tools::QueryScene.build(ctx)

      allow(Harness::Knowledge::Capture).to receive(:ingest)
      described_class.new.run(context: ctx, scene: scene, input: "any news?", step: step)
      expect(Harness::Knowledge::Capture).not_to have_received(:ingest)
    end

    it "judges the line on a CLEAN context: the claims prompt carries the line and what the speaker was handed, not the voicing thread" do
      reflection_prompt = nil
      ctx = context_with do |full|
        if full.include?("WORLD MEMORY — CLAIMS")
          reflection_prompt = full
          { "facts" => [] }.to_json
        elsif (full.include?("WORLD MEMORY") || full.include?("TAKING STOCK"))
          { "facts" => [] }.to_json
        elsif full.include?("filter stored facts")
          { "relevant" => [ 1 ] }.to_json   # grounded turn — reflection must still fire
        else
          { "speak" => true, "dialogue" => { "summary" => "answers", "prose" => "Aye, repealed, and good riddance." } }.to_json
        end
      end
      Knowledge.create!(content: "The salt tithe was repealed last winter.", location_id: tavern.id, current: true, game_time: 0)
      scene = Harness::Tools::QueryScene.build(ctx)

      described_class.new.run(context: ctx, scene: scene, input: "is there still a tithe?", step: step)
      expect(reflection_prompt).not_to include("\"player_input\"")                 # the voicing thread is axed — a clean context
      expect(reflection_prompt).to include("Aye, repealed, and good riddance.")    # the line under judgment
      expect(reflection_prompt).to include("records_given", "The salt tithe was repealed")  # what the speaker was handed, numbered
    end

    it "carries the closed subrole vocabulary into the reflection tail (no unexpanded marker)" do
      reflection_prompt = nil
      ctx = context_with do |full|
        if full.include?("WORLD MEMORY — CLAIMS")
          reflection_prompt = full
          { "facts" => [] }.to_json
        elsif full.include?("TAKING STOCK")
          { "assessment" => "held", "disposition" => "hold", "mood" => nil, "agenda" => "pursue" }.to_json
        elsif full.include?("filter stored facts")
          { "relevant" => [] }.to_json
        else
          { "speak" => true, "dialogue" => { "summary" => "gossips", "prose" => "Ask the drover out by the pens." } }.to_json
        end
      end
      scene = Harness::Tools::QueryScene.build(ctx)

      described_class.new.run(context: ctx, scene: scene, input: "any news?", step: step)
      expect(reflection_prompt).to include("drover, ")          # a vocab noun, singular, in the joined list
      expect(reflection_prompt).to include("never a group")
      expect(reflection_prompt).not_to include("<<SUBROLES>>")
    end

    it "does not reflect for a character who stayed silent" do
      reflected = false
      ctx = context_with do |full|
        reflected = true if (full.include?("SECOND PASS: WORLD MEMORY") || full.include?("TAKING STOCK"))
        { "speak" => false }.to_json
      end
      scene = Harness::Tools::QueryScene.build(ctx)

      described_class.new.run(context: ctx, scene: scene, input: "hello", step: step)
      expect(reflected).to be(false)
    end
  end

  describe "hearsay rendering (the hearer edge at recall)" do
    it "marks an event the holder only heard of, on both the recall path and the raw dump" do
      npc  = Npc.create!(name: "Kaol", subrole: "drover", location: tavern)
      ev   = Harness::Event::ForwardAppender.append(game_time: 0, scope: "local", location: tavern,
                                                    details: { "summary" => "The mill burned." },
                                                    participants: [ { character: barkeep, role: "subject" } ])
      EventParticipant.create!(event: ev, character: npc, role: "hearer")
      runner = described_class.new
      expect(runner.send(:dated_memory_text, ev, 3 * 1440, exclude_id: npc.id)).to eq("(3 days past, heard tell) The mill burned. (with Tomas)")
      # A hearer was told, not there: the subject's own recall names no hearer in its cast.
      expect(runner.send(:dated_memory_text, ev, 3 * 1440, exclude_id: barkeep.id)).to eq("(3 days past) The mill burned.")
      row = { "details" => ev.details, "participants" => ev.event_participants.map { |p| { "character_id" => p.character_id, "role" => p.role } } }
      expect(runner.send(:event_text, row, exclude_id: npc.id)).to start_with("(heard tell) The mill burned.")
    end
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
        @outcome = described_class.new.run(context: ctx, scene: scene, input: "talk to the recruit", step: step_to(nil, figure: 0))
      }.to change(Npc, :count).by(1)

      pc = @outcome.tool_calls.find { |t| t["name"] == "propose_character" }
      new_id = pc.dig("result", "character_id")
      expect(pc.dig("args", "from_extra")).to eq(recruit_desc)

      say = @outcome.tool_calls.find { |t| t["name"] == "propose_event" && t.dig("result", "staged") }
      actor_ids = say.dig("args", "participants").select { |p| p["role"] == "actor" }.map { |p| p["character_id"] }
      expect(actor_ids).to eq([ new_id ]) # the recruit speaks, not the barkeep
    end

    # Regression (the Reeds, run 2): two extras spoke in one turn; the first
    # promotion deleted its description IN PLACE from the array the runner's
    # scene hash aliased, so the second promotion looked up a shifted index
    # and minted the wrong figure. Scene arrays are now replaced, never
    # mutated: the captured view keeps its order, the Active moves on.
    it "the figure's trade and gender are judged once at promotion from its description, not named in the emit: the judge sees the looks and the trades alphabet, the row gets the trade, the name follows the gender" do
      seen = []
      ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
        llm_nuance: StubLLM.new { |full|
          seen << full
          if full.include?("WHO IS THIS FIGURE")
            { "reasoning" => "an old woman at her nets", "trade" => "net_mender", "gender" => "female" }.to_json
          elsif full.include?("wool, mending a net")
            { "speak" => true, "dialogue" => { "summary" => "answers", "prose" => "The old woman squints. \"Nets don't mend themselves.\"" } }.to_json
          elsif full.include?(KIND_MARK) then NO_CONTEST.to_json
          elsif full.include?(ACT_MARK) then NONE.to_json
          elsif full.include?("WORLD MEMORY") || full.include?("TAKING STOCK") then { "facts" => [], "people" => [], "places" => [] }.to_json
          else { "speak" => false }.to_json
          end
        })
      ctx.active_scene = Harness::Scene::Active.new(location: tavern, snapshot: Harness::Scene::Assembler.for(location: tavern), extras: [ "an old woman wrapped in wool, mending a net" ])
      expect {
        described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "talk to the old woman", step: step_to(nil, figure: 0))
      }.to change(Npc, :count).by(1)
      judge = JSON.parse(seen.find { |p| p.include?("WHO IS THIS FIGURE") }.split("INPUT:\n", 2).last)
      expect(judge["looks"]).to eq("an old woman wrapped in wool, mending a net")
      expect(judge["trades"]).to include("net_mender", "commoner")
      minted = Npc.order(:id).last
      expect(minted.subrole).to eq("net_mender")
      expect(minted.properties["gender"]).to eq("female") if minted.properties.key?("gender")
      expect(described_class::VOICING_SCHEMA["properties"]).not_to have_key("subrole")
      schema = Harness::Runners::Base.new.send(:promotion_schema)
      expect(schema["properties"].keys).to eq(%w[reasoning trade gender])
      expect(schema["required"]).to eq(schema["properties"].keys)
      named = File.read(Harness::Runners::Base::PROMOTION_PATH).split("Output:", 2).last.scan(/"(\w+)":/).flatten.uniq
      expect(named.sort).to eq(schema["properties"].keys.sort)
    end

    it "promotes the figure the plan addressed by index under its OWN description — the second of three, not the first (no index shift)" do
      huddled  = "a huddled figure under a frayed blanket near the firepit"
      traveler = "a thin traveler in a damp cloak, scanning the reeds"
      woman    = "an old woman wrapped in wool, quietly mending a net"
      voiced = []
      ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
        llm_nuance: StubLLM.new { |full|
          voiced << full if voicing?(full)
          if full.include?(traveler)
            { "speak" => true, "subrole" => "wanderer", "dialogue" => { "summary" => "adds", "prose" => "The traveler says the print led east." } }.to_json
          else
            { "speak" => false }.to_json
          end
        })
      ctx.active_scene = Harness::Scene::Active.new(
        location: tavern, snapshot: Harness::Scene::Assembler.for(location: tavern),
        extras: [ huddled, traveler, woman ]
      )
      scene = Harness::Tools::QueryScene.build(ctx)

      outcome = described_class.new.run(context: ctx, scene: scene, input: "ask the traveler about the reeds", step: step_to(nil, figure: 1))

      minted = outcome.tool_calls.select { |t| t["name"] == "propose_character" }
      expect(minted.map { |t| t.dig("args", "from_extra") }).to eq([ traveler ])
      expect(Npc.find(minted.first.dig("result", "character_id")).properties["physical"]).to eq(traveler)
      expect(voiced.any? { |v| v.include?(huddled) }).to be(false)                # only the addressed figure is polled
      expect(scene["present_extras"]).to eq([ huddled, traveler, woman ])         # the runner's view never shifted
      expect(ctx.active_scene.present_extras).to eq([ huddled, woman ])           # the Active moved on
    end

    it "reflects the debut line under the minted identity (no intake hole on promotion)" do
      ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
        llm_nuance: StubLLM.new { |full|
          if (full.include?("SECOND PASS: WORLD MEMORY") || full.include?("TAKING STOCK"))
            { "facts" => [ { "content" => "The garrison marches at dawn.", "concerns" => [] } ],
              "people" => [], "places" => [] }.to_json
          elsif full.include?(recruit_desc)
            { "speak" => true, "subrole" => "recruit",
              "dialogue" => { "summary" => "blurts it out", "prose" => "We march at dawn, all of us." } }.to_json
          else
            { "speak" => false }.to_json
          end
        })
      ctx.active_scene = Harness::Scene::Active.new(
        location: tavern,
        snapshot: Harness::Scene::Assembler.for(location: tavern),
        extras: [ recruit_desc ]
      )
      scene = Harness::Tools::QueryScene.build(ctx)

      expect {
        described_class.new.run(context: ctx, scene: scene, input: "talk to the recruit", step: step_to(nil, figure: 0))
      }.to change(Knowledge, :count).by(1)

      minted = Npc.order(:id).last
      expect(Knowledge.last.speaker).to eq(minted.name) # attributed to the promoted row, not "extra#0"
    end

    it "never polls an UNADDRESSED ambient extra (a horse doesn't fill a speaker slot or get minted)" do
      voiced = []
      ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100,
        llm_nuance: StubLLM.new { |full| voiced << full; { "speak" => false }.to_json })
      ctx.active_scene = Harness::Scene::Active.new(
        location: tavern,
        snapshot: Harness::Scene::Assembler.for(location: tavern),
        extras: [ "a lone horse whinnies softly from the stabling out back" ]
      )
      scene = Harness::Tools::QueryScene.build(ctx)

      expect {
        described_class.new.run(context: ctx, scene: scene, input: "hello barkeep", step: step("greet the barkeep"))
      }.not_to change(Npc, :count)                          # no phantom character minted
      expect(voiced.any? { |v| v.include?("lone horse") }).to be(false) # the horse was never voiced
    end
  end
  describe "the hands: the act judge reads the line (give / table / leave / attack)" do
    let(:city)   { Location.create!(name: "Saltmere") }
    let(:tavern) { Location.create!(name: "The Drowned Rat", parent: city) }
    let!(:docks) { Location.create!(name: "the Docks", parent: city, description: "wet planks") }

    # One stub for the whole turn: the voicing answers with `emit`, the act
    # judge with `act` (or `act_retry` when its bounce fires), the memory
    # judges get empty memory. `seen` collects every prompt.
    def act_ctx(emit, act: nil, act_retry: nil, seen: [])
      stub = StubLLM.new do |full|
        seen << full
        if full.include?("WORLD MEMORY") || full.include?("TAKING STOCK")
          { "facts" => [], "people" => [], "places" => [] }.to_json
        elsif full.include?(ACT_MARK)
          (full.include?("--- RETRY ---") && act_retry ? act_retry : act).to_json
        elsif full.include?(KIND_MARK)
          NO_CONTEST.to_json
        elsif full.include?(CHIME_MARK)
          NO_CHIME.to_json
        else
          emit.to_json
        end
      end
      Harness::Turn::Context.new(player_location: tavern, llm_nuance: stub, game_time: 100)
    end

    def line(prose = "Here.", speak: true)
      { "thought" => "Tomas decides.", "speak" => speak,
        "dialogue" => (speak ? { "summary" => "acts", "prose" => prose } : nil) }
    end

    def act(kind, **f) = NONE.merge("act" => kind).merge(f.transform_keys(&:to_s))

    def payload_of(prompt)
      body = prompt.split("INPUT:\n", 2).last
      JSON.parse(body[0..body.rindex("}")])
    end

    def act_prompts(seen) = seen.select { |p| p.include?(ACT_MARK) }
    def you_payload(seen) = payload_of(seen.find { |p| voicing?(p) })["you"]

    it "table puts a real thing on the table: a for-sale row here under the character's own word, the seller recorded, at the engine's price" do
      seen = []
      ctx = act_ctx(line("Tomas sets a jug down. \"This one's fair.\""), act: act("table", item: "a jug of last year's cider", category: "provisions"), seen: seen)
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "anything to drink?", step: step)

      judged = payload_of(act_prompts(seen).first)
      expect(judged["you"]).to include("id" => barkeep.id, "can_offer" => [ "provisions" ], "coins" => 0)
      expect(judged["you_said"]).to eq("Tomas sets a jug down. \"This one's fair.\"")
      expect(judged["player_said"]).to eq("anything to drink?")
      expect(judged["present"]).to include("id" => player.id, "name" => "Hero", "player" => true)
      item = Item.find_by(name: "jug of last year's cider")
      expect(item.location_id).to eq(tavern.id)
      expect(item.subrole).to eq("drink")   # the word picked the kind
      expect(item.properties).to include("for_sale" => true, "seller_id" => barkeep.id)
      offered = outcome.tool_calls.find { |t| t["name"] == "offer_item" }
      expect(offered.dig("result", "price")).to be >= 1
      expect(seen.find { |s| s.include?("WORLD MEMORY") }).to include("put jug of last year's cider on the table at")
    end

    it "the act prompt's output fields and the act grammar agree (a field the prompt names that the schema forbids is a silent drop)" do
      prompt = File.read(Harness::Runners::Conversation::ACT_PROMPT_PATH)
      output = prompt.split("Output:", 2).last
      named  = output.scan(/"(\w+)":/).flatten.uniq
      schema = Harness::Runners::Conversation::ACT_SCHEMA
      expect(named.sort).to eq(schema["properties"].keys.sort)
      expect(schema["required"].sort).to eq(schema["properties"].keys.sort)
      expect(output.scan(/"act": ((?:"\w+"\|?)+)/).flatten.first.scan(/\w+/).sort).to eq(Harness::Runners::Conversation::ACT_KINDS.sort)
    end

    it "the judge is told how the character looks, so a line about 'the weathered fisher' binds to them" do
      barkeep.update!(properties: (barkeep.properties || {}).merge("physical" => "a weathered fisher mending a net"))
      seen = []
      ctx = act_ctx(line("The weathered fisher takes the cheese with a nod."), act: NONE, seen: seen)
      described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "hold out the cheese", step: step)
      expect(payload_of(act_prompts(seen).first)["you"]["looks"]).to eq("a weathered fisher mending a net")
    end

    it "the judge sees the engine's receipts so far this turn, earlier steps' included" do
      seen = []
      ctx = act_ctx(line("Tomas stacks the jar."), act: NONE, seen: seen)
      ctx.turn_transcript = Harness::Turn::Transcript.new(input: "here's a coin for the honey")
      ctx.turn_transcript.record_tool_calls([ { "name" => "buy_item", "args" => {}, "result" => { "item_name" => "jar of honey", "price" => 1, "buyer_id" => player.id, "merchant_id" => barkeep.id } },
                                              { "name" => "query_scene", "args" => {}, "result" => {} } ])
      described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "here's a coin for the honey", step: step)
      receipts = payload_of(act_prompts(seen).first)["this_turn"]
      expect(receipts).to eq([ "You buy the jar of honey for 1 coin." ])
    end

    it "the judge runs at zero temperature with thinking off, reasoning first in its grammar; the voice runs at the defaults" do
      ctx = act_ctx(line, act: NONE)
      described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "hello", step: step)
      llm = ctx.llm_nuance
      act_i = llm.system_calls.index { |sys| sys.include?(ACT_MARK) }
      expect(llm.sampling_calls[act_i]).to eq(temperature: 0, thinking: false, max_tokens: nil)
      voice_i = llm.system_calls.index { |sys| !sys.include?(ACT_MARK) && !sys.include?("CONTEST") && !sys.include?("WORLD MEMORY") && !sys.include?("TAKING STOCK") }
      expect(llm.sampling_calls[voice_i]).to eq(temperature: nil, thinking: nil, max_tokens: Harness::Runners::Conversation::VOICING_MAX_TOKENS)
      schema = Harness::Runners::Conversation::ACT_SCHEMA
      expect(schema["properties"].keys.first).to eq("reasoning")
      expect(schema["required"]).to eq(schema["properties"].keys)
    end

    it "a thing outside the trade is refused without a second answer — told the allowed kinds, the judge once called a hoe a provision" do
      seen = []
      ctx = act_ctx(line, act: act("table", item: "a fine sword", category: "weapons"), act_retry: act("table", item: "a fine sword", category: "provisions"), seen: seen)
      described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "got a blade?", step: step)
      expect(act_prompts(seen).size).to eq(1)
      expect(Item.find_by(name: "fine sword")).to be_nil
    end

    it "someone with no trade has an empty can_offer, in the voice's payload and the judge's, and brings nothing out — refused, not bounced" do
      barkeep.update!(subrole: "labourer")
      jug = act("table", item: "a jug of cider", category: "provisions")
      seen = []
      ctx = act_ctx(line, act: jug, act_retry: jug, seen: seen)
      described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "anything to drink?", step: step)
      expect(you_payload(seen)["can_offer"]).to eq([])
      expect(payload_of(act_prompts(seen).first)["you"]["can_offer"]).to eq([])
      expect(act_prompts(seen).size).to eq(1)
      expect(Item.where(location_id: tavern.id)).to be_empty
    end

    it "the table has a cap: one more thing from a seller whose table is full drops" do
      cap = Harness::Items::Offers::TABLE_CAP
      cap.times { |i| Item.create!(name: "jug #{i}", location: tavern, properties: { "for_sale" => true, "seller_id" => barkeep.id, "tags" => [ "provision" ] }) }
      more = act("table", item: "one more jug", category: "provisions")
      seen = []
      ctx = act_ctx(line, act: more, act_retry: more, seen: seen)
      described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "more?", step: step)
      expect(act_prompts(seen).size).to eq(1)
      expect(Item.where(location_id: tavern.id).count).to eq(cap)
    end

    it "bringing things out is budgeted by clock phase" do
      key = Harness::Items::Offers.phase_key(100)
      barkeep.update!(properties: (barkeep.properties || {}).merge("brought_out" => { key => Harness::Items::Offers::PHASE_CAP }))
      jug = act("table", item: "a jug of cider", category: "provisions")
      seen = []
      ctx = act_ctx(line, act: jug, act_retry: jug, seen: seen)
      described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "another?", step: step)
      expect(act_prompts(seen).size).to eq(1)
      expect(Item.where(location_id: tavern.id)).to be_empty
    end

    it "give with a thing brought out mints it in the giver's hands and hands it over" do
      seen = []
      ctx = act_ctx(line("Eat."), act: act("give", to_id: player.id, item: "a heel of bread", category: "provisions"), seen: seen)
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "I'm starving", step: step)
      given = Item.find_by(name: "heel of bread")
      expect(given.character_id).to eq(player.id)
      expect(outcome.tool_calls.map { |t| t["name"] }).to include("give_item")
      expect(seen.find { |s| s.include?("WORLD MEMORY") }).to include("handed Hero heel of bread")
      expect(Harness::Items::Offers.brought_out(barkeep.reload, 100)).to eq(1)
    end

    it "give with an item_id hands over the very thing on the table: off sale, into the player's hands, no second row" do
      ale  = Item.create!(name: "dark ale", subrole: "drink", location: tavern, properties: { "for_sale" => true, "seller_id" => barkeep.id, "tags" => [ "provision" ] })
      seen = []
      ctx = act_ctx(line("On the house."), act: nil, seen: seen)
      # The judge picks the ware by id from its own payload (on_table).
      ctx.instance_variable_get(:@llm_nuance).instance_variable_set(:@block, lambda { |full|
        seen << full
        if full.include?("WORLD MEMORY") || full.include?("TAKING STOCK")
          { "facts" => [], "people" => [], "places" => [] }.to_json
        elsif full.include?(ACT_MARK)
          ware = payload_of(full).dig("you", "on_table").first
          act("give", to_id: player.id, item_id: ware["id"]).to_json
        else
          line("On the house.").to_json
        end
      })
      before = Item.count
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "could I have one of those?", step: step)
      given = Item.find_by(character_id: player.id)
      expect(given).to eq(ale)
      expect(given.properties.keys).not_to include("for_sale", "seller_id")
      expect(Item.count - before).to eq(0)   # the very row, no second one from the label
      expect(outcome.tool_calls.find { |t| t["name"] == "give_item" }.dig("args", "item_id")).to eq(given.id)
      expect(seen.find { |s| s.include?("WORLD MEMORY") }).to include("handed Hero #{given.name}")
    end

    it "give with the id of a thing lying loose here hands over that very thing — no second row from the label" do
      bow = Item.create!(name: "worn recurve bow", subrole: "weapon", location: tavern, properties: { "tags" => [ "weapon" ] })
      Item.create!(name: "cloudy cider", location: tavern, properties: { "for_sale" => true, "seller_id" => 999, "tags" => [ "provision" ] })   # another seller's ware — not hers to hand over
      seen = []
      ctx = act_ctx(line("Tomas lifts the bow off the bench. \"Look close.\""), act: act("give", to_id: player.id, item_id: bow.id), seen: seen)
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "hand me that bow a moment", step: step)
      judged = payload_of(act_prompts(seen).first)["you"]
      expect(judged["here"]).to eq([ { "id" => bow.id, "name" => "worn recurve bow" } ])
      expect(bow.reload.character_id).to eq(player.id)
      expect(bow.location_id).to be_nil
      expect(Item.where(name: "worn recurve bow").count).to eq(1)
      expect(outcome.tool_calls.find { |t| t["name"] == "give_item" }.dig("args", "item_id")).to eq(bow.id)
    end

    it "surfaces the purse to the voice as a fact" do
      barkeep.update!(coins: 7)
      seen = []
      ctx = act_ctx(line(speak: false), seen: seen)
      described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "hello barkeep", step: step)
      expect(you_payload(seen)["coins"]).to eq(7)
    end

    it "a silent character is not judged for an act: no line, no call, nothing moves" do
      barkeep.update!(coins: 4)
      Obligation.create!(debtor_id: barkeep.id, creditor_id: player.id, kind: "coins", amount: 2, terms: "the bet", status: "open", game_time: 0)
      seen = []
      ctx = act_ctx(line(speak: false), act: act("give", to_id: player.id, coins: 2), seen: seen)
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "well?", step: step)
      expect(act_prompts(seen)).to be_empty
      expect(outcome.tool_calls.map { |t| t["name"] }).to include("conversation_silence")
      expect(player.reload.coins).to eq(0)
    end

    it "give moves real coins through transfer_coins and settles the open debt" do
      barkeep.update!(coins: 10)
      ob = Obligation.create!(debtor_id: barkeep.id, creditor_id: player.id, kind: "coins", amount: 5, terms: "for the fish", status: "open", game_time: 0)
      seen = []
      ctx = act_ctx(line("Tomas counts five onto the bar."), act: act("give", to_id: player.id, coins: 5), seen: seen)
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "you owe me", step: step)

      expect(payload_of(act_prompts(seen).first)["you"]["debts"]).to be_present
      tc = outcome.tool_calls.find { |t| t["name"] == "transfer_coins" }
      expect(tc.dig("args", "from_id")).to eq(barkeep.id)
      expect(tc.dig("args", "to_id")).to eq(player.id)
      expect(tc.dig("args", "amount")).to eq(5)
      expect(barkeep.reload.coins).to eq(5)
      expect(player.reload.coins).to eq(5)
      expect(ob.reload.status).to eq("settled")
      reflection = seen.find { |s| s.include?("WORLD MEMORY") }
      expect(reflection).to include("\"did\"", "paid Hero 5 coins, settling the debt")
      expect(outcome.status).to eq(:ok)
    end

    it "coins leave a character only for a debt owed or a press lost — a seller handed two coppers does not pay them back" do
      barkeep.update!(coins: 10)
      back = act("give", to_id: player.id, coins: 2)
      seen = []
      ctx = act_ctx(line("Here you go."), act: back, act_retry: back, seen: seen)
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "here's your two coppers for the ale", step: step)
      expect(act_prompts(seen).size).to eq(1)   # refused, not bounced
      expect(outcome.tool_calls.map { |t| t["name"] }).not_to include("transfer_coins")
      expect(barkeep.reload.coins).to eq(10)
    end

    it "an unaffordable give bounces once with the purse named, then the corrected act executes" do
      barkeep.update!(coins: 3)
      Obligation.create!(debtor_id: barkeep.id, creditor_id: player.id, kind: "coins", amount: 5, terms: "for the fish", status: "open", game_time: 0)
      seen = []
      ctx = act_ctx(line, act: act("give", to_id: player.id, coins: 5), act_retry: act("give", to_id: player.id, coins: 3), seen: seen)
      described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "pay up", step: step)
      expect(act_prompts(seen).last).to include("--- RETRY ---", "Tomas has 3 coins, not 5")
      expect(barkeep.reload.coins).to eq(0)
      expect(player.reload.coins).to eq(3)
    end

    it "drops an act that is still wrong after the bounce and lets the line stand" do
      barkeep.update!(coins: 3)
      five = act("give", to_id: player.id, coins: 5)
      ctx = act_ctx(line("Take it."), act: five, act_retry: five)
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "pay up", step: step)
      expect(outcome.tool_calls.map { |t| t["name"] }).not_to include("transfer_coins")
      expect(outcome.tool_calls.find { |t| t["name"] == "propose_event" }.dig("args", "details")).to eq("Take it.")
      expect(barkeep.reload.coins).to eq(3)
    end

    it "a recipient id that is not here is refused, not guessed" do
      barkeep.update!(coins: 3)
      Obligation.create!(debtor_id: barkeep.id, creditor_id: player.id, kind: "coins", amount: 2, terms: "the bet", status: "open", game_time: 0)
      ghost = act("give", to_id: 999_999, coins: 2)
      seen = []
      ctx = act_ctx(line, act: ghost, act_retry: ghost, seen: seen)
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "pay up", step: step)
      expect(act_prompts(seen).last).to include("to_id 999999 is not a present id")
      expect(outcome.tool_calls.map { |t| t["name"] }).not_to include("transfer_coins")
    end

    it "a thing brought out with the category left blank bounces once with the trade's kinds named, then the corrected act lands it" do
      seen = []
      ctx = act_ctx(line("First one's on the house."),
                    act:       act("give", to_id: player.id, item: "a tankard of ale", category: ""),
                    act_retry: act("give", to_id: player.id, item: "a tankard of ale", category: "provisions"), seen: seen)
      described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "what can I get?", step: step)
      expect(act_prompts(seen).last).to include("--- RETRY ---", "`category` is empty — one of provisions")
      expect(Item.find_by(name: "tankard of ale")&.character_id).to eq(player.id)
    end

    it "leave relocates to the nearby place by id, pins them there, records the departure, and renders a line" do
      seen = []
      ctx = act_ctx(line("See you."), act: act("leave", place_id: docks.id), seen: seen)
      outcome = nil
      expect {
        outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "bye", step: step)
      }.to change(Event, :count).by(1)
      expect(payload_of(act_prompts(seen).first)["nearby_places"]).to include("id" => docks.id, "name" => "the Docks")
      expect(barkeep.reload.location_id).to eq(docks.id)
      expect(barkeep.properties.dig("pin", "location_id")).to eq(docks.id)
      expect(Event.last.details.dig("narrative", "details")).to eq("Tomas leaves for the Docks.")
      gone = outcome.tool_calls.find { |t| t["name"] == "npc_leave" }
      expect(gone.dig("args", "to")).to eq("the Docks")
      expect(Harness::Turn::Parts.render_call(gone, ctx, nil)[:text]).to eq("Tomas leaves for the Docks.")
    end

    it "leave with no place goes home, or up a level when home is here" do
      barkeep.update!(home_location_id: tavern.id)
      ctx = act_ctx(line("Off."), act: act("leave"))
      described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "bye", step: step)
      expect(barkeep.reload.location_id).to eq(city.id)
    end

    it "attack is refused for anyone who is not the fighting kind (the tavern-keep guarantee)" do
      swing = act("attack", to_id: player.id)
      seen = []
      ctx = act_ctx(line("Get out."), act: swing, act_retry: swing, seen: seen)
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "insult the barkeep", step: step)
      expect(act_prompts(seen).size).to eq(1)   # refused, not bounced
      expect(outcome.tool_calls.map { |t| t["name"] }).not_to include("start_combat")
      expect(outcome.status).to eq(:ok)
    end

    it "attack from a fighter starts combat against the player and terminates the turn as :combat" do
      barkeep.destroy!
      guard = Npc.create!(name: "Bruno", subrole: "guard", location: tavern, current_hp: 9, max_hp: 9, level: 1)
      allow_any_instance_of(Harness::Combat::Tools::StartCombat).to receive(:call).and_return({ "combat" => "started" })
      ctx = act_ctx({ "thought" => "Bruno has had enough.", "speak" => true, "dialogue" => { "summary" => "draws", "prose" => "Enough." } },
                    act: act("attack", to_id: player.id))
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "shove the guard", step: step("shove the guard"))
      fight = outcome.tool_calls.find { |t| t["name"] == "start_combat" }
      expect(fight.dig("args", "sides")).to eq([ { "name" => "player_party", "members" => [ player.id ] },
                                                { "name" => "hostiles",     "members" => [ guard.id ] } ])
      expect(fight.dig("args", "initiator_id")).to eq(guard.id)
      expect(outcome.status).to eq(:combat)
    end
  end

  describe "the ledger: four narrow judges (struck? → terms → delivered → discharged)" do
    NOT_STRUCK = { "reasoning" => "a quote, nothing taken", "struck" => false, "proposed_by" => "none", "accepted_by" => "none" }.freeze
    NOTHING_DISCHARGED = { "reasoning" => "nothing closed", "discharged" => [] }.freeze

    # One stub for the turn: the voice says `prose`, the act judge answers
    # `act`, the four ledger judges answer their fixtures, the claims judge
    # and taking stock get empty memory. `seen` collects every prompt.
    def ledger_ctx(prose, struck: NOT_STRUCK, terms: nil, delivered: nil, discharged: NOTHING_DISCHARGED, act: NONE, seen: [])
      stub = StubLLM.new do |full|
        seen << full
        if    full.include?("BARGAINS: STRUCK")     then struck.to_json
        elsif full.include?("BARGAINS: TERMS")      then terms.to_json
        elsif full.include?("BARGAINS: DELIVERED")  then delivered.to_json
        elsif full.include?("BARGAINS: DISCHARGED") then discharged.to_json
        elsif full.include?("WORLD MEMORY") || full.include?("TAKING STOCK") then { "facts" => [], "people" => [], "places" => [] }.to_json
        elsif full.include?("filter stored facts")  then { "relevant" => [] }.to_json
        elsif full.include?(ACT_MARK)               then act.to_json
        elsif full.include?(KIND_MARK)              then NO_CONTEST.to_json
        elsif full.include?(CHIME_MARK)             then NO_CHIME.to_json
        else { "thought" => "…", "speak" => true, "dialogue" => { "summary" => "speaks", "prose" => prose } }.to_json
        end
      end
      Harness::Turn::Context.new(player_location: tavern, llm_nuance: stub, game_time: 100)
    end

    def run!(ctx, input) = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: input, step: step)
    def prompts(seen, mark) = seen.select { |p| p.include?(mark) }
    def payload_of(prompt)
      body = prompt.split("INPUT:\n", 2).last
      JSON.parse(body[0..body.rindex("}")])
    end
    def struck(prop, acc) = { "reasoning" => "terms taken", "struck" => true, "proposed_by" => prop, "accepted_by" => acc }
    def side(who, kind, terms, amount: nil) = { "who" => who, "kind" => kind, "amount" => amount, "terms" => terms }
    def terms(*sides, due: nil, where: nil) = { "reasoning" => "sides", "sides" => sides, "due" => due, "where" => where }

    it "most turns close nothing: one struck call per speaker on both lines, the recent exchange, the turn's receipts and the pair's open debts — no terms call, no rows" do
      seen = []
      ctx = ledger_ctx("Two coppers for the ale, if you want it.", seen: seen)
      expect { run!(ctx, "how much for an ale?") }.not_to change(Obligation, :count)
      gates = prompts(seen, "BARGAINS: STRUCK")
      expect(gates.size).to eq(1)
      judged = payload_of(gates.first)
      expect(judged).to include("you" => { "name" => "Tomas" }, "player" => { "name" => "Hero" },
                                "player_said_now" => "how much for an ale?", "you_said" => "Two coppers for the ale, if you want it.",
                                "open_debts" => [])
      expect(judged["exchange"]).to be_an(Array)
      expect(judged["this_turn"]).to be_an(Array)
      expect(prompts(seen, "BARGAINS: TERMS")).to be_empty
      expect(prompts(seen, "BARGAINS: DELIVERED")).to be_empty
      expect(prompts(seen, "BARGAINS: DISCHARGED")).to be_empty   # no debts stand, no call
    end

    it "a bargain struck with nothing carried out books every side, names bound by the runner from player|you, due and where carried" do
      seen = []
      ctx = ledger_ctx("Done. Five coppers, and the ale is yours at dusk.", seen: seen,
                       struck: struck("player", "you"),
                       terms: terms(side("player", "coins", "Five coppers for the ale", amount: 5), side("you", "deed", "Hand over the ale"), due: "at dusk", where: "the Drowned Rat"))
      expect { run!(ctx, "five coppers for an ale, deal?") }.to change(Obligation, :count).by(2)
      judged = payload_of(prompts(seen, "BARGAINS: TERMS").first)
      expect(judged).to include("proposed_by" => "player", "accepted_by" => "you")
      expect(judged).not_to have_key("this_turn")
      expect(prompts(seen, "BARGAINS: DELIVERED")).to be_empty   # no receipts this turn, nothing to subtract
      coins, deed = Obligation.order(:id).last(2)
      expect(coins).to have_attributes(debtor_id: player.id, creditor_id: barkeep.id, kind: "coins", amount: 5, due: "at dusk", location_id: tavern.id)
      expect(deed).to have_attributes(debtor_id: barkeep.id, creditor_id: player.id, kind: "deed", terms: "Hand over the ale")
    end

    it "a swap accepted and half carried out by the hands: the side the receipts show is history, the other side is the debt (hands run 4, t9)" do
      seen = []
      ctx = ledger_ctx("Aye, straight trade — your cider for my stew.", seen: seen,
                       act: NONE.merge("act" => "give", "to_id" => player.id, "item" => "a bowl of stew", "category" => "provisions"),
                       struck: struck("player", "you"),
                       terms: terms(side("player", "deed", "Hand Tomas the sour cider"), side("you", "deed", "Hand Hero the bowl of stew")),
                       delivered: { "reasoning" => "the stew went over", "delivered" => [ 2 ] })
      expect { run!(ctx, "swap you — my cider for your stew") }.to change(Obligation, :count).by(1)
      judged = payload_of(prompts(seen, "BARGAINS: DELIVERED").first)
      expect(judged["sides"].map { |x| x["n"] }).to eq([ 1, 2 ])
      expect(judged["this_turn"]).to include(a_string_matching(/\ATomas hands you the bowl of stew\.\z/))
      expect(Obligation.last).to have_attributes(debtor_id: player.id, creditor_id: barkeep.id, kind: "deed", terms: "Hand Tomas the sour cider")
    end

    it "a one-word bystander line with a standing swap on the books strikes nothing (hands run 5, t8): the debt is shown as standing, the discharge judge runs and closes nothing, no second row" do
      standing = Obligation.create!(debtor: player, creditor: barkeep, kind: "deed", terms: "Trade the strap for the cheese", game_time: 90)
      seen = []
      ctx = ledger_ctx("Left.", seen: seen)
      expect { run!(ctx, "pick a hand") }.not_to change(Obligation, :count)
      expect(payload_of(prompts(seen, "BARGAINS: STRUCK").first)["open_debts"]).to eq([ "Hero owes Tomas — Trade the strap for the cheese" ])
      judged = payload_of(prompts(seen, "BARGAINS: DISCHARGED").first)
      expect(judged["open_debts"]).to eq([ { "id" => standing.id, "line" => "Hero owes Tomas — Trade the strap for the cheese" } ])
      expect(judged).not_to have_key("exchange")
      expect(standing.reload.status).to eq("open")
    end

    it "a struck answer with one side doing both, or nobody accepting, is a proposal left hanging: no terms call, no row" do
      [ struck("you", "you"), struck("player", "none") ].each do |gate|
        seen = []
        expect { run!(ledger_ctx("Two coppers and it's yours.", seen: seen, struck: gate), "how much?") }.not_to change(Obligation, :count)
        expect(prompts(seen, "BARGAINS: TERMS")).to be_empty
      end
    end

    it "a standing debt named by id settles when released; a coin debt only that way, and 'delivered' with no receipt this turn is refused" do
      deed  = Obligation.create!(debtor: barkeep, creditor: player, kind: "deed", terms: "Mend the net", game_time: 90)
      coins = Obligation.create!(debtor: player, creditor: barkeep, kind: "coins", amount: 3, terms: "Three for the ale", game_time: 90)
      ctx = ledger_ctx("The net can wait. And we'll call the three coppers square.",
                       discharged: { "reasoning" => "net claimed done, coins let go", "discharged" => [ { "id" => deed.id, "how" => "delivered" }, { "id" => coins.id, "how" => "delivered" } ] })
      run!(ctx, "how's my net coming?")
      expect(deed.reload.status).to eq("open")    # nothing changed hands this turn: a delivery claim has no receipt behind it
      expect(coins.reload.status).to eq("open")   # coins die by transfer or release, never by delivery in words
      ctx = ledger_ctx("Forget the net, and the coppers too.",
                       discharged: { "reasoning" => "both let go", "discharged" => [ { "id" => deed.id, "how" => "released" }, { "id" => coins.id, "how" => "released" } ] })
      run!(ctx, "how's my net coming?")
      expect(deed.reload.status).to eq("settled")
      expect(coins.reload.status).to eq("settled")
    end

    it "a standing deed settles as delivered when the hands carried it out this turn (the receipt is the proof)" do
      deed = Obligation.create!(debtor: barkeep, creditor: player, kind: "deed", terms: "Hand over the bowl of stew", game_time: 90)
      ctx = ledger_ctx("Here's your stew, as promised.",
                       act: NONE.merge("act" => "give", "to_id" => player.id, "item" => "a bowl of stew", "category" => "provisions"),
                       discharged: { "reasoning" => "the stew went over", "discharged" => [ { "id" => deed.id, "how" => "delivered" } ] })
      run!(ctx, "where's my stew?")
      expect(Item.find_by(name: "bowl of stew").character_id).to eq(player.id)
      expect(deed.reload.status).to eq("settled")
    end

    it "the four ledger judges run at zero temperature with thinking off, reasoning first in each grammar, every field the prompts name in the grammar" do
      seen = []
      ctx = ledger_ctx("Two coppers.", seen: seen)
      run!(ctx, "how much?")
      llm = ctx.llm_nuance
      i = llm.system_calls.index { |sys| sys.include?("BARGAINS: STRUCK") }
      expect(llm.sampling_calls[i]).to eq(temperature: 0, thinking: false, max_tokens: nil)
      c = Harness::Runners::Conversation
      { c::LEDGER_STRUCK_PATH => c::LEDGER_STRUCK_SCHEMA, c::LEDGER_TERMS_PATH => c::LEDGER_TERMS_SCHEMA,
        c::LEDGER_DELIVERED_PATH => c::LEDGER_DELIVERED_SCHEMA, c::LEDGER_DISCHARGED_PATH => c::LEDGER_DISCHARGED_SCHEMA }.each do |path, schema|
        expect(schema["properties"].keys.first).to eq("reasoning")
        expect(schema["required"]).to eq(schema["properties"].keys)
        named = File.read(path).split("Output:", 2).last.scan(/"(\w+)":/).flatten.uniq
        known = []
        walk = ->(sch) { (sch["properties"] || {}).each { |k, v| known << k; walk.call(v); walk.call(v["items"]) if v["items"] } }
        walk.call(schema)
        expect(named - known).to eq([]), "#{File.basename(path)} names #{(named - known).inspect} outside its grammar"
      end
    end
  end


  describe "the chime-in gate (C0): a bystander's one question before their voicing" do
    let!(:maud) { Npc.create!(name: "Maud", subrole: "fishwife", location: tavern, properties: { "personality" => "never lets a price pass" }) }

    def gate_ctx(chime:, seen: [])
      stub = StubLLM.new do |full|
        seen << full
        if full.include?(CHIME_MARK) then { "reasoning" => "judged", "chime_in" => chime }.to_json
        elsif full.include?(KIND_MARK) then NO_CONTEST.to_json
        elsif full.include?(ACT_MARK) then NONE.to_json
        elsif full.include?("WORLD MEMORY") || full.include?("TAKING STOCK") then { "facts" => [], "people" => [], "places" => [] }.to_json
        elsif full.include?("filter stored facts") then { "relevant" => [] }.to_json
        elsif full.include?(%("id": #{barkeep.id},)) then { "speak" => true, "dialogue" => { "summary" => "answers", "prose" => "Tomas shrugs. \"Two coppers.\"" } }.to_json
        else { "speak" => true, "dialogue" => { "summary" => "adds", "prose" => "Maud snorts. \"Two? Robbery.\"" } }.to_json
        end
      end
      ctx = Harness::Turn::Context.new(player_location: tavern, llm_nuance: stub, game_time: 100)
      ctx.active_scene = Harness::Scene::Active.new(location: tavern, snapshot: Harness::Scene::Assembler.for(location: tavern), extras: [],
                                                    internal_state: { maud.id => "sour" }, agendas: { maud.id => "sell the herring" }, doing: { maud.id => "gutting fish" })
      ctx.active_scene.record_line!(maud.id, "Maud said her piece earlier.")
      ctx
    end
    def voicings(seen) = seen.select { |p| voicing?(p) }

    it "asks the bystander one question on who they are, the player's words to the other, what was said so far and their own last line; a no spends no voicing" do
      seen = []
      ctx = gate_ctx(chime: false, seen: seen)
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "Tomas, how much for an ale?", step: step_to(barkeep.id))
      gate = JSON.parse(seen.find { |p| p.include?(CHIME_MARK) }.split("INPUT:\n", 2).last)
      expect(gate["you"]).to eq("name" => "Maud", "subrole" => "fishwife", "personality" => "never lets a price pass", "mood" => "sour", "agenda" => "sell the herring", "doing" => "gutting fish")
      expect(gate).to include("player_said" => "Tomas, how much for an ale?", "addressed" => "Tomas", "said_this_turn" => [ "Tomas shrugs. \"Two coppers.\"" ], "you_said_last" => "Maud said her piece earlier.")
      expect(voicings(seen).size).to eq(1)   # Tomas only
      expect(outcome.tool_calls.count { |t| t["name"] == "propose_event" && t.dig("result", "staged") }).to eq(1)
      expect(ctx.llm_nuance.sampling_calls[seen.index { |p| p.include?(CHIME_MARK) }]).to eq(temperature: 0, thinking: false, max_tokens: nil)
    end

    it "a yes voices the bystander (without recall, as before) and their line lands" do
      seen = []
      ctx = gate_ctx(chime: true, seen: seen)
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "Tomas, how much for an ale?", step: step_to(barkeep.id))
      expect(voicings(seen).size).to eq(2)
      expect(outcome.tool_calls.count { |t| t["name"] == "propose_event" && t.dig("result", "staged") }).to eq(2)
      expect(seen.none? { |p| p.include?("filter stored facts") && p.include?("Maud") }).to be(true)
    end

    it "an open-mic turn (nobody addressed) asks no gate: everyone is polled as before" do
      seen = []
      ctx = gate_ctx(chime: false, seen: seen)
      described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "how much for an ale, anyone?", step: step)
      expect(seen.none? { |p| p.include?(CHIME_MARK) }).to be(true)
      expect(voicings(seen).size).to eq(2)
    end

    it "the gate's grammar: reasoning first, both required, the prompt's fields in it" do
      schema = described_class::CHIME_SCHEMA
      expect(schema["properties"].keys).to eq(%w[reasoning chime_in])
      expect(schema["required"]).to eq(schema["properties"].keys)
      named = File.read(described_class::CHIME_PROMPT_PATH).split("Output:", 2).last.scan(/"(\w+)":/).flatten.uniq
      expect(named.sort).to eq(schema["properties"].keys.sort)
    end
  end

end
