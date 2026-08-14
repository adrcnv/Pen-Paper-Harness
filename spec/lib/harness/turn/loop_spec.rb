require "rails_helper"
require "tmpdir"

RSpec.describe Harness::Turn::Loop do
  let(:city)   { Location.create!(name: "Saltmere") }
  let(:tavern) { Location.create!(name: "Tavern", parent: city) }
  let(:warehouse) { Location.create!(name: "Warehouse", parent: city) }

  # Reasoning input now includes the player's id so the model can tag itself
  # as a participant. Production guarantees Player.first exists (bin/play asserts).
  let!(:player) { Player.create!(name: "Hero", subrole: "adventurer", location: tavern) }
  # Noon: day phase, so classified venues (the Warehouse) are open and the
  # barred-door gate stays out of these mechanics tests' way.
  let(:context) { Harness::Turn::Context.new(player_location: tavern, game_time: 720) }

  # Scripted state-machine harness (the agentic loop is deleted): a stub
  # runner executes the scripted tool calls through a REAL Resolver — same
  # execution surface the runners use — and the dispatcher is stubbed to a
  # one-step plan naming it. Loop infrastructure (TurnLog, seeds, snapshots,
  # scene lifecycle, narration) runs for real around it.
  class ScriptedRunner < Harness::Runners::Base
    def initialize(calls) = @calls = calls

    def run(context:, scene:, input:, step:)
      resolver = Harness::Resolver.new(context: context)
      tcs = @calls.map { |c|
        call = Harness::LLM::ToolCall.new(name: c[:tool], args: c[:args])
        { "name" => call.name, "args" => call.args, "result" => resolver.execute(call) }
      }
      Harness::Runners::Outcome.new(tool_calls: tcs, status: :ok)
    end
  end

  def scripted_loop(calls, narration: "(narration)", context: self.context)
    allow(Harness::Planner).to receive(:plan_for).and_return(
      "plan" => [ { "runner" => "scripted", "reason" => "scripted", "args" => {} } ],
      "parse_error" => nil, "raw" => "", "duration_ms" => 1, "model" => "fake", "world" => {}
    )
    adapter = Harness::LLM::FakeAdapter.new(narration: narration)
    described_class.new(adapter: adapter, context: context,
                        registry: { "scripted" => ScriptedRunner.new(calls) })
  end

  def run(reasoning:, narration: "(narration)")
    scripted_loop(reasoning, narration: narration).run_turn(input: "player input")
  end

  # A scripted personal event is the mechanical floor's smallest visible
  # render: its details become a :line part verbatim.
  def event_call(details)
    { tool: "propose_event", args: { "scope" => "personal", "trigger" => "beat", "details" => details } }
  end

  describe "happy path" do
    it "executes scripted runner tool calls through the resolver; pure reads render nothing" do
      maren = Npc.create!(name: "Maren", subrole: "barkeep", location: tavern)
      transcript = run(
        reasoning: [
          { tool: "query_scene",     args: {} },
          { tool: "query_character", args: { "character_id" => maren.id } }
        ]
      )
      expect(transcript.tool_calls.size).to eq(2)
      expect(transcript.tool_calls.first["name"]).to eq("query_scene")
      expect(transcript.tool_calls.last["result"]).to include("name" => "Maren")
      # No narration model exists; reads produce no display parts.
      expect(transcript.parts).to eq([])
      expect(transcript.narration).to eq("")
    end

    it "persists a TurnLog row with the full trace" do
      expect {
        run(reasoning: [ { tool: "query_scene", args: {} }, event_call("narration") ])
      }.to change(TurnLog, :count).by(1)
      row = TurnLog.last
      expect(row.narration).to eq("narration")
      expect(row.reasoning_tool_calls.size).to eq(2)
      expect(row.reasoning_tool_calls.first["name"]).to eq("query_scene")
      expect(row.turn_number).to eq(1)
    end

    it "increments turn_number across turns" do
      run(reasoning: [])
      run(reasoning: [])
      expect(TurnLog.pluck(:turn_number)).to eq([ 1, 2 ])
    end

    it "appends input/narration to the context history" do
      run(reasoning: [ event_call("the tavern is dim") ])
      expect(context.history).to eq([ { "input" => "player input", "narration" => "the tavern is dim" } ])
    end
  end

  describe "replay rig (session state, snapshots, seeds)" do
    it "flushes the scene buffer + history to the session_states singleton at the turn boundary" do
      run(reasoning: [ event_call("the tavern is dim") ])
      row = SessionState.current
      expect(row).to be_present
      expect(row.location_id).to eq(tavern.id)
      expect(row.scene["location_id"]).to eq(tavern.id)
      expect(row.scene["narrations"].last["narration"]).to eq("the tavern is dim")
      expect(row.history.size).to eq(1)
      expect(row.prompt_hash).to be_present
    end

    it "overwrites the singleton each turn (the buffer mirrors the CURRENT scene only)" do
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "turn two")
      loop_obj = described_class.new(adapter: adapter, context: context)
      loop_obj.run_turn(input: "one")
      loop_obj.run_turn(input: "two")
      expect(SessionState.count).to eq(1)
      expect(SessionState.current.scene["narrations"].size).to eq(2)
    end

    it "stamps the turn's seed onto the TurnLog and honors a forced seed (retry)" do
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "seeded")
      described_class.new(adapter: adapter, context: context).run_turn(input: "hi", seed: 424_242)
      expect(TurnLog.last.llm_seed).to eq(424_242)
      expect(Harness::LLM::Seed.current).to eq(424_242)

      described_class.new(adapter: adapter, context: context).run_turn(input: "again")
      expect(TurnLog.last.llm_seed).to be_present
    end

    it "reseeds the dice RNG per turn: a forced seed replays the same rolls" do
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "x")
      loop_obj = described_class.new(adapter: adapter, context: context)

      loop_obj.run_turn(input: "hi", seed: 7)
      first = Array.new(5) { Harness::Dice.check(actor_stat: 10).roll }
      loop_obj.run_turn(input: "hi", seed: 7)
      second = Array.new(5) { Harness::Dice.check(actor_stat: 10).roll }
      expect(first).to eq(second)
    end
  end

  # VACUUM INTO cannot run inside a transaction, so this group opts out of
  # transactional fixtures and cleans up after itself.
  describe "per-turn snapshot (VACUUM INTO)" do
    self.use_transactional_tests = false

    after do
      [ TurnLog, SessionState, EventParticipant, Event, Character, Item, Location ].each(&:delete_all)
    end

    it "writes a complete per-turn save-state file when snapshot_dir is set" do
      loc = Location.create!(name: "Snapville")
      Player.create!(name: "Hero", location: loc)
      ctx = Harness::Turn::Context.new(player_location: loc)
      Dir.mktmpdir do |dir|
        adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "snap")
        described_class.new(adapter: adapter, context: ctx, snapshot_dir: dir).run_turn(input: "hi")
        snap = File.join(dir, "turn_#{TurnLog.maximum(:turn_number)}.sqlite")
        expect(File.exist?(snap)).to be(true)
        # The snapshot is a full save-state: the session_states row (scene
        # buffer + stamps) is INSIDE the file.
        db = SQLite3::Database.new(snap)
        count = db.execute("SELECT COUNT(*) FROM session_states").first.first
        db.close
        expect(count).to eq(1)
      end
    end
  end

  describe "scene transition" do
    it "tool call mutates the context and clears scene_dirty by end-of-turn (mid-turn rebuild)" do
      run(
        reasoning: [ { tool: "transition", args: { "destination_id" => warehouse.id } } ],
        narration: "..."
      )
      expect(context.player_location).to eq(warehouse)
      # scene_dirty is cleared inside the same turn — between reasoning and
      # narration — so the destination scene is populated when narration
      # records against it. See "limbo fix" in turn/loop.rb.
      expect(context.scene_dirty).to be(false)
    end

    it "rebuilds at end of the dirty turn, not at the start of next turn" do
      run(
        reasoning: [ { tool: "transition", args: { "destination_id" => warehouse.id } } ],
        narration: "..."
      )
      expect(context.scene_dirty).to be(false)
      expect(context.active_scene.location).to eq(warehouse)
      run(reasoning: [], narration: "...")
      expect(context.scene_dirty).to be(false)
    end

    it "drops conversation history at the scene boundary (theory-of-mind discipline)" do
      # Turn 1 at the tavern records a narration ("Tormund spilled the beans").
      # Turn 2 transitions to the warehouse. The warehouse scene's buffer —
      # what every voicing/recall consumer reads as recent history — must NOT
      # carry the tavern's narration. Structural: narrations wipe at exit.
      run(reasoning: [ event_call("Tormund spilled the beans about a courier named Corren") ])
      run(reasoning: [ { tool: "transition", args: { "destination_id" => warehouse.id } } ])

      buffer = context.active_scene.narrations.map { |n| n["narration"] }.join("\n")
      expect(buffer).not_to include("Tormund")
      expect(buffer).not_to include("Corren")

      # Global session history is preserved (for /history debug, session log).
      expect(context.history.size).to eq(2)
      expect(context.history.map { |t| t["narration"] }).to include("Tormund spilled the beans about a courier named Corren")
    end
  end

  describe "player reference scrub" do
    let(:loop_obj) {
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "(n)")
      described_class.new(adapter: adapter, context: context)
    }

    it "scrubs the engine phrase 'the player' to the player's name (incl. possessive)" do
      out = loop_obj.send(:scrub_player_reference,
        "Astrid looks the player up and down, weighing the player's robes.")
      expect(out).to eq("Astrid looks Hero up and down, weighing Hero’s robes.")
    end

    it "does not touch a bare 'player' (a dice-player in a crowd stays)" do
      out = loop_obj.send(:scrub_player_reference, "two players roll dice; a lone player watches")
      expect(out).to eq("two players roll dice; a lone player watches")
    end

    it "builds an out-of-character notice from the unresolved reason" do
      notice = loop_obj.send(:unresolved_notice, "destination 'forest' not found")
      expect(notice).to match(/out of character/i)
      expect(notice).to include("destination 'forest' not found")
      expect(notice).to match(/rephras/i)
    end
  end

  # The player's eyes: appended dead last on every non-combat turn, and
  # DISPLAY-ONLY — the prose renders but never enters scene history, the
  # context buffer, or the persisted narration (fact-laundering firewall).
  describe "perception (the player's eyes)" do
    it "appends a :perception part last with its display record, kept OUT of the buffer" do
      allow(Harness::Turn::Perception).to receive(:render).and_return("The fire gutters low.")
      transcript = run(reasoning: [ event_call("You pocket the coin.") ])

      expect(transcript.parts.last).to eq({ kind: :perception, text: "The fire gutters low." })
      expect(transcript.tool_calls.last["name"]).to eq("display_perception")
      # Display-only: the buffer join and everything downstream of it
      # (scene history, context turns, TurnLog narration) exclude the prose.
      expect(transcript.narration).to eq("You pocket the coin.")
      expect(TurnLog.last.narration).not_to include("fire gutters")
      expect(context.history.last["narration"]).not_to include("fire gutters")
    end

    it "a flaked or silent render adds nothing — mechanical parts carry the turn" do
      allow(Harness::Turn::Perception).to receive(:render).and_return(nil)
      transcript = run(reasoning: [ event_call("You pocket the coin.") ])
      expect(transcript.parts.map { |p| p[:kind] }).to eq([ :line ])
      expect(transcript.tool_calls.map { |t| t["name"] }).not_to include("display_perception")
    end

    it "runs after initiative so the eyes read every voice, and the engine word is scrubbed" do
      allow(Harness::Turn::Perception).to receive(:render).and_return("Dust hangs where the player stood.")
      transcript = run(reasoning: [ event_call("You pocket the coin.") ])
      expect(transcript.parts.last[:text]).to eq("Dust hangs where Hero stood.")
    end

    it "delta gate: renders once, then stays silent while the view holds (same scene, same phase)" do
      allow(Harness::Turn::Perception).to receive(:render).and_return("The room settles.")
      loop_obj = scripted_loop([ event_call("You pocket the coin.") ])
      loop_obj.run_turn(input: "first")
      second = loop_obj.run_turn(input: "second")
      expect(Harness::Turn::Perception).to have_received(:render).once
      expect(second.parts.map { |p| p[:kind] }).not_to include(:perception)
    end

    it "delta gate: a clock-phase crossing renders as a DELTA, not a re-establishment" do
      allow(Harness::Turn::Perception).to receive(:render).and_return("The room settles.")
      allow(Harness::Turn::Perception).to receive(:render_delta).and_return("The light goes amber.")
      loop_obj = scripted_loop([ event_call("You pocket the coin.") ])
      loop_obj.run_turn(input: "first")                 # establishes, stamps the view (day, 12:00)
      context.game_time = 1100                          # 18:20 — evening
      second = loop_obj.run_turn(input: "second")
      expect(Harness::Turn::Perception).to have_received(:render).once
      expect(Harness::Turn::Perception).to have_received(:render_delta).once do |delta:, **|
        expect(delta).to eq({ "time_of_day" => "evening" })
      end
      expect(second.parts.last).to eq({ kind: :perception, text: "The light goes amber." })
    end

    it "delta gate: a flaked render leaves the gate open to retry next turn" do
      allow(Harness::Turn::Perception).to receive(:render).and_return(nil, "The room settles.")
      loop_obj = scripted_loop([ event_call("You pocket the coin.") ])
      loop_obj.run_turn(input: "first")                 # flake — no stamp
      second = loop_obj.run_turn(input: "second")       # retried
      expect(Harness::Turn::Perception).to have_received(:render).twice
      expect(second.parts.map { |p| p[:kind] }).to include(:perception)
    end

    it "delta gate: a present NPC settling into a different activity renders only that shift" do
      npc = Npc.create!(name: "Osric", subrole: "porter", location: tavern)
      allow(Harness::Turn::Perception).to receive(:render).and_return("The room settles.")
      allow(Harness::Turn::Perception).to receive(:render_delta).and_return("Osric paces.")
      loop_obj = scripted_loop([ event_call("You pocket the coin.") ])
      loop_obj.run_turn(input: "first")                                 # establishes, stamps the view
      context.active_scene.update_doing!(npc.id, "pacing the floor")    # taking-stock moves someone
      loop_obj.run_turn(input: "second")
      expect(Harness::Turn::Perception).to have_received(:render).once
      expect(Harness::Turn::Perception).to have_received(:render_delta).once do |delta:, **|
        expect(delta["people"]).to eq([ { "name" => "Osric", "role" => "porter", "doing" => "pacing the floor" } ])
      end
      loop_obj.run_turn(input: "third")                                 # re-stamped — silent again
      expect(Harness::Turn::Perception).to have_received(:render_delta).once
    end

    it "delta gate: an ABSENT character's doing is invisible — no fire" do
      allow(Harness::Turn::Perception).to receive(:render).and_return("The room shifts.")
      loop_obj = scripted_loop([ event_call("You pocket the coin.") ])
      loop_obj.run_turn(input: "first")
      context.active_scene.update_doing!(999_999, "pacing")   # nobody present has this id
      loop_obj.run_turn(input: "second")
      expect(Harness::Turn::Perception).to have_received(:render).once
    end

    it "delta gate: an explicit look renders even when nothing changed" do
      allow(Harness::Turn::Perception).to receive(:render).and_return("You take it in again.")
      allow(Harness::Planner).to receive(:plan_for).and_return(
        "plan" => [ { "runner" => "inspection", "reason" => "look", "args" => {} } ],
        "parse_error" => nil, "raw" => "", "duration_ms" => 1, "model" => "fake", "world" => {}
      )
      adapter  = Harness::LLM::FakeAdapter.new(narration: "(n)")
      loop_obj = described_class.new(adapter: adapter, context: context,
                                     registry: { "inspection" => Harness::Runners::Inspection.new })
      loop_obj.run_turn(input: "look around")   # establishes + stamps
      loop_obj.run_turn(input: "look again")    # same phase — the look alone re-opens
      expect(Harness::Turn::Perception).to have_received(:render).twice
    end
  end

  # The mechanical floor: typed parts from committed tool calls, in causal
  # order, no model call anywhere. Causal authority = rendering authority.
  describe "mechanical parts (Turn::Parts)" do
    let(:staged) {
      { "name" => "propose_event",
        "args" => { "details" => "Bess doesn't stop moving. 'I just pour the ale, sir.'" },
        "result" => { "staged" => true } }
    }
    let(:resolve) {
      { "name" => "resolve", "args" => { "actor_id" => 1 },
        "result" => { "outcome" => "success", "action" => "press", "stat" => "charisma", "roll" => 15, "against" => 10 } }
    }

    def compose(tcs, unresolved: nil, runners: [])
      t = Harness::Turn::Transcript.new(input: "x", location_id: tavern.id)
      t.record_tool_calls(tcs)
      t.unresolved = unresolved
      t.runners_ran.concat(runners)
      Harness::Turn::Parts.compose(transcript: t, context: context, scene: nil)
    end

    it "renders a staged line as a verbatim :dialogue part; reads render nothing" do
      parts = compose([ { "name" => "query_events", "args" => {}, "result" => {} }, staged ])
      expect(parts).to eq([ { kind: :dialogue, text: "Bess doesn't stop moving. 'I just pour the ale, sir.'" } ])
    end

    it "resolves the staged line's speaker from the actor participant — metadata only, not text" do
      bess = Npc.create!(name: "Bess", location: tavern)
      tagged = staged.merge("args" => staged["args"].merge(
        "participants" => [
          { "character_id" => bess.id, "role" => "actor" },
          { "character_id" => player.id, "role" => "participant" }
        ]
      ))
      parts = compose([ tagged ])
      expect(parts.first[:speaker]).to eq("Bess")
      expect(parts.first[:text]).not_to include("[Bess]") # the label never enters the text
    end

    it "renders bracket before dialogue, in tool-call order" do
      parts = compose([ resolve, staged ])
      expect(parts.map { |p| p[:kind] }).to eq([ :bracket, :dialogue ])
      expect(parts.first[:text]).to eq("[press — Charisma 15 vs 10: success]")
    end

    it "labels the bracket with the capitalized stat and flags criticals" do
      tcs = [ { "name" => "resolve", "args" => {}, "result" => {
        "action" => "Climb the wall", "stat" => "strength", "roll" => 20, "against" => 10,
        "outcome" => "critical_success", "margin" => "decisive", "critical" => true
      } } ]
      expect(compose(tcs).first[:text])
        .to eq("[Climb the wall — Strength 20 vs 10: critical_success, decisive, critical]")
    end

    it "renders a short personal event as a :line, and drops a long one whole (no mid-string cuts)" do
      short = { "name" => "propose_event", "args" => { "scope" => "personal", "details" => "a real event" }, "result" => {} }
      long  = { "name" => "propose_event", "args" => { "scope" => "personal", "details" => "x" * 300 }, "result" => {} }
      parts = compose([ short, long ])
      expect(parts).to eq([ { kind: :line, text: "a real event" } ])
    end

    it "renders an unresolved intent as a trailing :stock stall" do
      parts = compose([ resolve ], unresolved: "walk into a forest")
      expect(parts.last).to eq({ kind: :stock, text: "Nothing comes of it — walk into a forest." })
    end

    it "renders an off-scene propose_location as a discovery line, and skips one entered via the chain" do
      offscene = { "name" => "propose_location",
                   "args" => { "name" => "The Muddy Pint", "description" => "A smoke-choked dockside tavern." },
                   "result" => { "location_id" => tavern.id + 999 } }
      here     = { "name" => "propose_location", "args" => { "name" => "Cellar" },
                   "result" => { "location_id" => tavern.id } }
      parts = compose([ offscene, here ])
      expect(parts).to eq([ { kind: :line, text: "You learn of The Muddy Pint — A smoke-choked dockside tavern." } ])
    end

    it "renders a runner's display_fragment verbatim and travel legs as lines" do
      frag = { "name" => "display_fragment", "args" => { "text" => "The bark splits." }, "result" => { "rendered" => true } }
      trav = { "name" => "travel", "args" => {},
               "result" => { "outcome" => "arrived", "destination" => { "id" => 9, "name" => "Oarhaven" }, "minutes" => 300 } }
      parts = compose([ frag, trav ])
      expect(parts).to eq([
        { kind: :fragment, text: "The bark splits." },
        { kind: :line, text: "The road brings you to Oarhaven — 5 hours traveled." }
      ])
    end

    it "renders conversation_silence as stock and skips errored calls whole" do
      silence = { "name" => "conversation_silence", "args" => {}, "result" => { "nobody_spoke" => true } }
      errored = { "name" => "pickup", "args" => {}, "result" => { "error" => "no item" } }
      parts = compose([ errored, silence ])
      expect(parts).to eq([ { kind: :stock, text: "No one reacts." } ])
    end
  end

  describe "budgets" do
    it "trims conversation history to history_cap after appending the turn" do
      history_cap = 2
      context.history << { "input" => "older", "narration" => "older" }
      context.history << { "input" => "old",   "narration" => "old" }

      scripted_loop([ event_call("new") ], context: context)
        .tap { |l| l.instance_variable_set(:@history_cap, history_cap) }
        .run_turn(input: "now")

      expect(context.history.size).to eq(history_cap)
      expect(context.history.last["narration"]).to eq("new")
    end
  end

  describe "scene manager integration" do
    it "enters a scene at the player's location on the first turn" do
      Npc.create!(name: "Maren", subrole: "barkeep", location: tavern)
      run(reasoning: [], narration: "the room is dim")

      expect(context.active_scene).not_to be_nil
      expect(context.active_scene.location).to eq(tavern)
      expect(context.active_scene.present_characters.map(&:name)).to include("Maren")
    end

    it "records the turn's narration on the active scene" do
      run(reasoning: [ event_call("the bar is mostly empty") ])
      expect(context.active_scene.narrations).to eq(
        [ { "input" => "player input", "narration" => "the bar is mostly empty" } ]
      )
    end

    it "exits old + enters new BETWEEN reasoning and narration when scene_dirty fires mid-turn" do
      run(
        reasoning: [ { tool: "transition", args: { "destination_id" => warehouse.id } } ],
        narration: "you arrive in the warehouse"
      )
      # By end of the dirty turn, the scene has already rebuilt — the
      # narration (the mechanical arrival card) recorded against the
      # destination scene, NOT the origin. This is the limbo fix: Turn N+1's
      # recent_history reads the warehouse's narrations, not an empty list
      # (origin scene narrations are wiped at exit).
      expect(context.active_scene.location).to eq(warehouse)
      expect(context.active_scene.narrations.last["narration"]).to include("Warehouse")

      # A subsequent non-transitioning turn finds itself at the same scene,
      # no further rebuild needed.
      run(reasoning: [], narration: "the room is dim")
      expect(context.active_scene.location).to eq(warehouse)
    end
  end

  # Initiation gate (dice-rolled NPC unprompted action) was retired in favor
  # of agendas (Scene::InternalState produces an optional player-targeted
  # agenda for at most one NPC per scene; the reasoning loop reads it from
  # query_scene and decides when to push). No per-turn dice roll here anymore;
  # the agenda is structural, not stochastic.

  describe "error path" do
    it "persists a TurnLog with error set when the loop raises" do
      # The narration model call is gone, so break the turn upstream: the
      # dispatcher's planner raising escapes run_turn's begin block.
      allow(Harness::Planner).to receive(:plan_for).and_raise("planner exploded")
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "n")

      expect {
        described_class.new(adapter: adapter, context: context).run_turn(input: "x")
      }.to raise_error(/planner exploded/)

      row = TurnLog.last
      expect(row.error).to match(/planner exploded/)
      expect(row.narration).to be_nil
    end
  end

  describe "mid-combat player slot (structured, not agentic)" do
    it "routes an in-combat input through Combat::PlayerTurn — dispatcher and reasoning loop skipped" do
      vek = Npc.create!(name: "Vek", location: tavern, current_hp: 5, max_hp: 5)
      adapter   = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "n")
      turn_loop = described_class.new(adapter: adapter, context: context)
      turn_loop.run_turn(input: "look around")   # enter the scene

      active = context.active_scene
      active.start_combat!
      active.combat.add_combatant(player.id, side: "player_party")
      active.combat.add_combatant(vek.id, side: "foes")
      active.combat.initiative = [ player.id, vek.id ]

      expect(Harness::Combat::PlayerTurn).to receive(:run) do |kwargs|
        expect(kwargs[:input]).to eq("I attack Vek")
        expect(kwargs[:player]).to eq(player)
        nil   # non-action → slot stays fresh; Combat::Loop yields
      end
      transcript = turn_loop.run_turn(input: "I attack Vek")
      expect(transcript.combat.end_reason).to eq(:yielded)
    end
  end

  describe "combat hand-off" do
    let!(:vek) { Npc.create!(name: "Vek", subrole: "marauder", location: tavern, current_hp: 18, max_hp: 18) }

    it "runs the round driver after a runner fires start_combat and assembles round narration" do
      # Stub Termination so pre-flight returns nil (combat proceeds) but
      # end-of-round-1 returns :victory. Without two-step, the new pre-flight
      # check would catch :victory immediately and no round would run.
      call_count = 0
      allow(Harness::Combat::Termination).to receive(:evaluate) do
        call_count += 1
        call_count == 1 ? nil : :victory
      end

      # Pre-mark the player slot as exercised — simulates the player's
      # combat resolve. Without this, the loop would YIELD at the fresh
      # player slot before any round ran. The scripted start_combat call
      # fires, then a custom hook marks tokens.
      player_id = player.id
      allow(Harness::Combat::Tools::StartCombat).to receive(:new).and_wrap_original do |orig, *args|
        instance = orig.call(*args)
        original_call = instance.method(:call)
        instance.define_singleton_method(:call) do |a, ctx|
          result = original_call.call(a, ctx)
          if ctx.active_scene&.in_combat?
            ctx.active_scene.combat.mark_acted!(player_id)
          end
          result
        end
        instance
      end

      transcript = run(
        reasoning: [
          { tool: "start_combat",
            args: {
              "sides" => [
                { "name" => "player_party", "members" => [ player.id ] },
                { "name" => "marauders",    "members" => [ vek.id ] }
              ],
              "inciting_beat" => "Mud drew steel on Vek"
            } }
        ],
        narration: "(unused — combat owns the narration)"
      )
      start_combat_call = transcript.tool_calls.find { |c| c["name"] == "start_combat" }
      expect(start_combat_call).not_to be_nil
      expect(start_combat_call["result"]["error"]).to be_nil, "start_combat returned error: #{start_combat_call['result']['error']}"
      expect(transcript.combat).to be_a(Harness::Combat::Loop::Result)
      expect(transcript.combat.end_reason).to eq(:victory)
      expect(transcript.narration).not_to eq("(unused — combat owns the narration)")
      expect(transcript.narration).to include("Round 1") # fallback prose path when adapter doesn't produce combat round narration
    end

    it "yields when a runner fires start_combat but the player slot is fresh" do
      transcript = run(
        reasoning: [
          { tool: "start_combat",
            args: {
              "sides" => [
                { "name" => "player_party", "members" => [ player.id ] },
                { "name" => "marauders",    "members" => [ vek.id ] }
              ],
              "inciting_beat" => "Mud refuses to back down"
            } }
        ],
        narration: "regular narration body"
      )
      expect(transcript.combat).to be_a(Harness::Combat::Loop::Result)
      expect(transcript.combat.end_reason).to eq(:yielded)
      expect(transcript.combat.rounds).to eq(0)
      # Scene stays in combat; the next turn drives the player's first slot
      # through Combat::PlayerTurn.
      expect(context.active_scene&.in_combat?).to be(true)
      expect(context.scene_dirty).to be(false)
      # Bootstrap-yield with no rounds → the mechanical parts path ran.
      expect(transcript.narration).to eq("⚔ The fight begins.")
    end
  end
end
