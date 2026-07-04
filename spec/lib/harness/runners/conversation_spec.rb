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

  # Named people are now realized by the post-turn Knowledge::Capture pass (the
  # single entity pipe), not a per-emit `claims` field. The capture LLM returns
  # a `people` list; capture hands each to the Realizer.
  def capture_people(*people, dialogue: "Ask for Harek at the relay.")
    context_with do |full|
      if full.include?("WORLD MEMORY")
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
    # Count VOICING calls only — the post-turn capture pass (WORLD MEMORY) is orthogonal.
    voicing = polled.reject { |p| p.include?("WORLD MEMORY") || p.include?("filter stored facts") }
    expect(voicing.size).to eq(2)
  end

  describe "knowledge recall (substantive speaker)" do
    it "recalls a gate-approved fact into the substantive speaker's voicing context" do
      Knowledge.create!(content: "The salt tithe was repealed last winter.", location_id: tavern.id, current: true, game_time: 0)
      voicing_prompt = nil
      ctx = context_with do |full|
        if full.include?("filter stored facts")   # the relevance gate (synthetic ids: fact is candidate #1)
          { "relevant" => [ 1 ] }.to_json
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

    it "does not recall (no gate call) when the NPC has no matching knowledge" do
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

  describe "knowledge capture" do
    it "captures a world-fact from spoken dialogue" do
      ctx = context_with do |full|
        if full.include?("WORLD MEMORY")   # the capture call
          { "facts" => [ { "content" => "The salt tithe was repealed last winter.", "subrole" => nil, "scope" => "local", "min_int" => nil } ] }.to_json
        else                               # the barkeep's voicing call
          { "speak" => true, "dialogue" => { "summary" => "gossips", "prose" => "They say the salt tithe was repealed last winter." } }.to_json
        end
      end
      scene = Harness::Tools::QueryScene.build(ctx)

      expect {
        described_class.new.run(context: ctx, scene: scene, input: "any news?", step: step)
      }.to change(Knowledge, :count).by(1)
      expect(Knowledge.last.content).to match(/salt tithe/)
    end

    it "SKIPS capture when recall grounded the substantive speaker (gate arms capture)" do
      Knowledge.create!(content: "The salt tithe was repealed last winter.", location_id: tavern.id, current: true, game_time: 0)
      capture_ran = false
      ctx = context_with do |full|
        if full.include?("filter stored facts")   # gate grounds (candidate #1 relevant) → disarms capture
          { "relevant" => [ 1 ] }.to_json
        elsif full.include?("WORLD MEMORY")        # capture — must NOT run
          capture_ran = true
          { "facts" => [] }.to_json
        else
          { "speak" => true, "dialogue" => { "summary" => "answers", "prose" => "Aye, repealed." } }.to_json
        end
      end
      scene = Harness::Tools::QueryScene.build(ctx)
      described_class.new.run(context: ctx, scene: scene, input: "is there still a tithe?", step: step)
      expect(capture_ran).to be(false)
    end

    it "still captures on a recall MISS (gate returns none)" do
      Knowledge.create!(content: "An unrelated fact about the docks.", location_id: tavern.id, current: true, game_time: 0)
      ctx = context_with do |full|
        if full.include?("filter stored facts")
          { "relevant" => [] }.to_json           # MISS → arms capture
        elsif full.include?("WORLD MEMORY")
          { "facts" => [ { "content" => "The bridge toll doubled at midsummer.", "subrole" => nil, "scope" => "local", "min_int" => nil } ] }.to_json
        else
          { "speak" => true, "dialogue" => { "summary" => "x", "prose" => "The toll doubled." } }.to_json
        end
      end
      scene = Harness::Tools::QueryScene.build(ctx)
      expect {
        described_class.new.run(context: ctx, scene: scene, input: "what's new?", step: step)
      }.to change(Knowledge, :count).by(1)
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
        @outcome = described_class.new.run(context: ctx, scene: scene, input: "talk to the recruit", step: step("address the recruit"))
      }.to change(Npc, :count).by(1)

      pc = @outcome.tool_calls.find { |t| t["name"] == "propose_character" }
      new_id = pc.dig("result", "character_id")
      expect(pc.dig("args", "from_extra")).to eq(recruit_desc)

      say = @outcome.tool_calls.find { |t| t["name"] == "propose_event" && t.dig("result", "staged") }
      actor_ids = say.dig("args", "participants").select { |p| p["role"] == "actor" }.map { |p| p["character_id"] }
      expect(actor_ids).to eq([ new_id ]) # the recruit speaks, not the barkeep
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
end
