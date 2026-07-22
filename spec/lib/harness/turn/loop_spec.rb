require "rails_helper"
require "tmpdir"

RSpec.describe Harness::Turn::Loop do
  let(:city)   { Location.create!(name: "Saltmere") }
  let(:tavern) { Location.create!(name: "Tavern", parent: city) }
  let(:warehouse) { Location.create!(name: "Warehouse", parent: city) }

  # Reasoning input now includes the player's id so the model can tag itself
  # as a participant. Production guarantees Player.first exists (bin/play asserts).
  let!(:player) { Player.create!(name: "Hero", subrole: "adventurer", location: tavern) }
  let(:context) { Harness::Turn::Context.new(player_location: tavern) }

  def run(reasoning:, narration: "(narration)", mode: nil)
    adapter = Harness::LLM::FakeAdapter.new(reasoning: reasoning, narration: narration)
    described_class.new(adapter: adapter, context: context, mode: mode).run_turn(input: "player input")
  end

  describe "happy path" do
    it "dispatches reasoning-loop tool calls through the resolver and narrates" do
      maren = Npc.create!(name: "Maren", subrole: "barkeep", location: tavern)
      transcript = run(
        reasoning: [
          { tool: "query_scene",     args: {} },
          { tool: "query_character", args: { "character_id" => maren.id } }
        ],
        narration: "You ask; Maren is evasive."
      )
      expect(transcript.tool_calls.size).to eq(2)
      expect(transcript.tool_calls.first["name"]).to eq("query_scene")
      expect(transcript.tool_calls.last["result"]).to include("name" => "Maren")
      expect(transcript.narration).to eq("You ask; Maren is evasive.")
    end

    it "persists a TurnLog row with the full trace" do
      expect {
        run(reasoning: [ { tool: "query_scene", args: {} } ], narration: "narration")
      }.to change(TurnLog, :count).by(1)
      row = TurnLog.last
      expect(row.narration).to eq("narration")
      expect(row.reasoning_tool_calls.size).to eq(1)
      expect(row.reasoning_tool_calls.first["name"]).to eq("query_scene")
      expect(row.turn_number).to eq(1)
    end

    it "increments turn_number across turns" do
      run(reasoning: [], narration: "t1")
      run(reasoning: [], narration: "t2")
      expect(TurnLog.pluck(:turn_number)).to eq([ 1, 2 ])
    end

    it "appends input/narration to the context history" do
      run(reasoning: [], narration: "the tavern is dim")
      expect(context.history).to eq([ { "input" => "player input", "narration" => "the tavern is dim" } ])
    end
  end

  describe "replay rig (session state, snapshots, seeds)" do
    it "flushes the scene buffer + history to the session_states singleton at the turn boundary" do
      run(reasoning: [], narration: "the tavern is dim")
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

  describe "tool error protocol" do
    it "passes {error:} back to the model rather than crashing the turn" do
      transcript = run(
        reasoning: [ { tool: "query_character", args: { "character_id" => 99_999 } } ],
        narration: "..."
      )
      expect(transcript.tool_calls.first["result"]).to include("error")
      expect(transcript.error).to be_nil
    end

    it "passes unknown-tool errors back the same way" do
      transcript = run(
        reasoning: [ { tool: "nonexistent", args: {} } ],
        narration: "..."
      )
      expect(transcript.tool_calls.first["result"]["error"]).to match(/unknown tool/)
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
      # Turn 1 at the tavern accumulates a narration ("Tormund spilled the beans").
      # Turn 2 transitions to the warehouse — narration follows the transition.
      # Turn 3 happens at the warehouse and is what we're asserting against:
      # its reasoning input must NOT contain the tavern's prior narration.
      adapter = Harness::LLM::FakeAdapter.new(
        reasoning: [],
        narration: "Tormund spilled the beans about a courier named Corren"
      )
      described_class.new(adapter: adapter, context: context).run_turn(input: "press Tormund")

      transition_adapter = Harness::LLM::FakeAdapter.new(
        reasoning: [ { tool: "transition", args: { "destination_id" => warehouse.id } } ],
        narration: "you walk over to the warehouse"
      )
      described_class.new(adapter: transition_adapter, context: context).run_turn(input: "go to warehouse")

      # Capture the reasoning input on turn 3 (post-transition).
      captured_reasoning_input = nil
      observing_adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "...")
      observing_adapter.define_singleton_method(:start_turn) do |system:, user:, tools:|
        captured_reasoning_input = user
        super(system: system, user: user, tools: tools)
      end
      described_class.new(adapter: observing_adapter, context: context).run_turn(input: "look around the warehouse")

      # Tavern narration must not have leaked into the warehouse turn's input.
      expect(captured_reasoning_input).not_to include("Tormund")
      expect(captured_reasoning_input).not_to include("Corren")
      # The structural marker: recent_history is empty at the new scene.
      expect(captured_reasoning_input).to match(/"recent_history":\s*\[\s*\]/)

      # Global session history is preserved (for /history debug, session log).
      expect(context.history.size).to eq(3)
      expect(context.history.map { |t| t["narration"] }).to include("Tormund spilled the beans about a courier named Corren")
    end
  end

  describe "narration tool_call sanitization" do
    let(:loop_obj) {
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "(n)")
      described_class.new(adapter: adapter, context: context)
    }

    it "strips internal_state and agenda from query_scene present_characters" do
      tcs = [ {
        "name" => "query_scene", "args" => {},
        "result" => {
          "location" => { "id" => 1, "name" => "Tavern" },
          "present_characters" => [
            { "id" => 2, "name" => "Rask", "subrole" => "bandit",
              "internal_state" => "drumming his axe handle",
              "agenda" => "wants to demand toll",
              "abilities" => [ { "name" => "Heavy Strike", "uses_remaining" => 3 } ] }
          ]
        }
      } ]

      out = loop_obj.send(:sanitize_tool_calls_for_narration, tcs)
      char = out.first["result"]["present_characters"].first
      expect(char.keys).to contain_exactly("id", "name", "subrole", "abilities")
      expect(char).not_to have_key("internal_state")
      expect(char).not_to have_key("agenda")
    end

    it "blanks the staged event's result summary so the narrator never sees the debug bracket" do
      tcs = [ {
        "name" => "propose_event",
        "args" => { "details" => "Rhys wipes the bar. 'Paranoia, mostly.'" },
        "result" => { "staged" => true, "summary" => "[dialogue — rendered, not persisted]" }
      } ]
      out = loop_obj.send(:sanitize_tool_calls_for_narration, tcs)
      expect(out.first["result"]).to eq({ "staged" => true })
      expect(out.first.to_json).not_to include("not persisted")
      expect(out.first.to_json).not_to include("Paranoia")  # details swapped for the marker
    end

    it "leaves non-query_scene tool_calls untouched" do
      tcs = [ {
        "name" => "resolve", "args" => { "actor_id" => 1 },
        "result" => { "outcome" => "success", "internal_state" => "should not strip" }  # contrived
      } ]
      out = loop_obj.send(:sanitize_tool_calls_for_narration, tcs)
      expect(out).to eq(tcs)
    end

    it "scrubs the engine phrase 'the player' to the player's name (incl. possessive)" do
      out = loop_obj.send(:scrub_player_reference,
        "Astrid looks the player up and down, weighing the player's robes.")
      expect(out).to eq("Astrid looks Hero up and down, weighing Hero’s robes.")
    end

    it "does not touch a bare 'player' (a dice-player in a crowd stays)" do
      out = loop_obj.send(:scrub_player_reference, "two players roll dice; a lone player watches")
      expect(out).to eq("two players roll dice; a lone player watches")
    end

    it "leaves query_scene results without present_characters untouched" do
      tcs = [ {
        "name" => "query_scene", "args" => {},
        "result" => { "location" => { "id" => 1, "name" => "Empty Hall" }, "present_characters" => [] }
      } ]
      out = loop_obj.send(:sanitize_tool_calls_for_narration, tcs)
      expect(out).to eq(tcs)
    end
  end

  describe "staged dialogue rendering (structural)" do
    let(:loop_obj) {
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "MODEL PROSE")
      described_class.new(adapter: adapter, context: context)
    }
    let(:staged) {
      { "name" => "propose_event",
        "args" => { "details" => "Bess doesn't stop moving. 'I just pour the ale, sir.'" },
        "result" => { "staged" => true } }
    }
    let(:resolve) {
      { "name" => "resolve", "args" => { "actor_id" => 1 },
        "result" => { "outcome" => "success", "action" => "press", "stat" => "charisma", "roll" => 15, "against" => 10 } }
    }

    it "extracts staged dialogue lines verbatim, ignoring non-staged and reads" do
      tcs = [ { "name" => "query_events", "args" => {}, "result" => {} },
              staged,
              { "name" => "propose_event", "args" => { "details" => "bookkeeping" }, "result" => {} } ]
      lines = loop_obj.send(:staged_dialogue_lines, tcs)
      expect(lines).to eq([ "Bess doesn't stop moving. 'I just pour the ale, sir.'" ])
    end

    it "composes brackets, then model body, then dialogue last" do
      out = loop_obj.send(:compose_narration, "She relents.", [ resolve, staged ])
      expect(out).to eq("[press — Charisma 15 vs 10: success]\n\nShe relents.\n\nBess doesn't stop moving. 'I just pour the ale, sir.'")
    end

    it "renders dialogue alone when there is no model body (dialogue-only turn)" do
      out = loop_obj.send(:compose_narration, "", [ staged ])
      expect(out).to eq("Bess doesn't stop moving. 'I just pour the ale, sir.'")
    end

    it "treats a pure conversation turn as NOT needing the narration model" do
      expect(loop_obj.send(:other_narratable?, [ staged, { "name" => "query_events" } ])).to be(false)
      expect(loop_obj.send(:other_narratable?, [ staged, resolve ])).to be(true)
      expect(loop_obj.send(:other_narratable?, [ { "name" => "transition" } ])).to be(true)
    end

    it "keeps a contest-tagged resolve inside the dialogue-only skip (untagged resolves still narrate)" do
      contest = resolve.merge("contest" => true)
      expect(loop_obj.send(:other_narratable?, [ staged, contest ])).to be(false)
      # The bracket line still renders — only the model call is skipped.
      out = loop_obj.send(:compose_narration, "", [ contest, staged ])
      expect(out).to eq("[press — Charisma 15 vs 10: success]\n\nBess doesn't stop moving. 'I just pour the ale, sir.'")
    end

    it "hides the staged words from the model, leaving a marker" do
      out = loop_obj.send(:sanitize_tool_calls_for_narration, [ staged ])
      expect(out.first.dig("args", "details")).to eq(described_class::STAGED_DIALOGUE_MARKER)
      expect(out.first.dig("args", "details")).not_to include("pour the ale")
    end

    it "leaves a non-staged propose_event untouched" do
      ev = { "name" => "propose_event", "args" => { "details" => "a real event" }, "result" => { "staged" => false } }
      expect(loop_obj.send(:sanitize_tool_calls_for_narration, [ ev ])).to eq([ ev ])
    end
  end

  describe "player identity in narration" do
    # Regression: the narration payload had no player identity, so when an NPC
    # addressed the player aloud the model borrowed a present character's name
    # ("Maud, if you're hunting ghosts," Maud says — to the player). The player
    # is now surfaced so dialogue can name them correctly.
    let(:loop_obj) {
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "(n)")
      described_class.new(adapter: adapter, context: context)
    }

    it "surfaces the player's name (and gender) to the narration step" do
      player.update!(properties: (player.properties || {}).merge("gender" => "female"))
      loop_obj.instance_variable_get(:@scene_manager).ensure_entered
      transcript = Harness::Turn::Transcript.new(input: "ask about Harek", location_id: tavern.id)

      msg = loop_obj.send(:narration_user_message, "ask about Harek", transcript)

      expect(msg).to include("\"player\"")
      expect(msg).to include("\"name\": \"Hero\"")
      expect(msg).to include("\"gender\": \"female\"")
    end
  end

  describe "off-scene creation partitioning for narration" do
    # Regression: "look for a tavern" makes a runner create a sublocation +
    # its proprietor + a kickoff event at the NEW location while the player
    # stays put. Those creation tool_calls used to reach narration verbatim
    # and the weak model rendered them as the present scene — teleporting the
    # player in and staging the proprietor's greeting. The partition strips
    # off-scene creations before narration; new places surface only as a flat
    # `discovered_nearby` list, off-scene characters/events are dropped.
    let(:loop_obj) {
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "(n)")
      described_class.new(adapter: adapter, context: context)
    }
    let(:here_id) { tavern.id }
    let(:elsewhere) { tavern.id + 999 } # a location that is not where the player stands

    it "collapses an off-scene propose_location into discovered_nearby (name + description only)" do
      tcs = [ {
        "name" => "propose_location",
        "args" => { "name" => "The Muddy Pint", "description" => "A smoke-choked dockside tavern.", "type" => "sublocation" },
        "result" => { "location_id" => elsewhere }
      } ]
      kept, discoveries = loop_obj.send(:partition_offscene_creations, tcs, here_id)
      expect(kept).to be_empty
      expect(discoveries).to eq([ { "name" => "The Muddy Pint", "description" => "A smoke-choked dockside tavern." } ])
    end

    it "drops off-scene propose_character and propose_event entirely (no discovery, not kept)" do
      tcs = [
        { "name" => "propose_character", "args" => { "name" => "Garrick", "location_id" => elsewhere }, "result" => { "character_id" => 7 } },
        { "name" => "propose_event", "args" => { "location_id" => elsewhere, "details" => "Garrick looks up as you enter." }, "result" => { "event_id" => 9 } }
      ]
      kept, discoveries = loop_obj.send(:partition_offscene_creations, tcs, here_id)
      expect(kept).to be_empty
      expect(discoveries).to be_empty
    end

    it "keeps creation calls AT the player's current location" do
      tcs = [
        { "name" => "propose_location", "args" => { "name" => "Cellar" }, "result" => { "location_id" => here_id } },
        { "name" => "propose_event", "args" => { "location_id" => here_id, "details" => "Maren slams the tankard down." }, "result" => { "event_id" => 3 } }
      ]
      kept, discoveries = loop_obj.send(:partition_offscene_creations, tcs, here_id)
      expect(kept).to eq(tcs)
      expect(discoveries).to be_empty
    end

    it "leaves non-creation tool_calls untouched" do
      tcs = [
        { "name" => "query_scene", "args" => {}, "result" => { "present_characters" => [] } },
        { "name" => "resolve", "args" => { "actor_id" => 1 }, "result" => { "outcome" => "success" } }
      ]
      kept, discoveries = loop_obj.send(:partition_offscene_creations, tcs, here_id)
      expect(kept).to eq(tcs)
      expect(discoveries).to be_empty
    end
  end

  describe "narration sees current_scene after a mid-turn rebuild" do
    # Regression: when the reasoning loop fires transition + query_scene
    # in one turn, query_scene returns the destination's PRE-materialization
    # state (empty). The limbo fix rebuilds the scene before narration, but
    # the tool_calls in narration's input still capture the empty result.
    # Without current_scene, narration would render an empty room. With it,
    # narration sees the populated post-rebuild scene.
    it "current_scene reflects the populated destination after transition" do
      # Pre-seed the destination with NPCs so the assembler returns them
      # post-rebuild (no materializer needed for this regression test).
      Npc.create!(name: "Bram", subrole: "owner", location: warehouse, current_hp: 5, max_hp: 5)
      Npc.create!(name: "Silt", subrole: "bartender", location: warehouse, current_hp: 5, max_hp: 5)

      captured_narration_user = nil
      adapter = Harness::LLM::FakeAdapter.new(
        reasoning: [ { tool: "transition", args: { "destination_id" => warehouse.id } } ],
        narration: "(rendered)"
      )
      adapter.define_singleton_method(:complete) do |system:, user:|
        captured_narration_user = user
        super(system: system, user: user)
      end

      described_class.new(adapter: adapter, context: context).run_turn(input: "go to the warehouse")

      expect(captured_narration_user).to include("\"current_scene\"")
      expect(captured_narration_user).to include("Bram")
      expect(captured_narration_user).to include("Silt")
    end

    it "sends static set-dressing only on the establishing narration of a scene" do
      # Repeated-narration driver: re-feeding the location description + extras
      # prose every turn invites the model to reprint them. They go out only on
      # the first narration of a scene (narrations empty); later turns get the
      # name + present set only.
      tannery = Location.create!(name: "Tannery", description: "The reek of lye and wet hide hangs over the vats.")
      context.player_location = tannery
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "(n)")
      loop_inst = described_class.new(adapter: adapter, context: context)
      sm = loop_inst.instance_variable_get(:@scene_manager)
      transcript = Harness::Turn::Transcript.new(input: "x", location_id: tannery.id)

      establishing_scene = Harness::Scene::Active.new(
        location: tannery, snapshot: Harness::Scene::Assembler.for(location: tannery),
        narrations: [], extras: [ "a vat of foul brown liquid" ]
      )
      sm.instance_variable_set(:@active, establishing_scene)
      first = loop_inst.send(:narration_user_message, "look around", transcript)
      expect(first).to include("The reek of lye and wet hide") # description present
      expect(first).to include("a vat of foul brown liquid")   # extras present

      later_scene = Harness::Scene::Active.new(
        location: tannery, snapshot: Harness::Scene::Assembler.for(location: tannery),
        narrations: [ { "input" => "look around", "narration" => "(already established)" } ],
        extras: [ "a vat of foul brown liquid" ]
      )
      sm.instance_variable_set(:@active, later_scene)
      later = loop_inst.send(:narration_user_message, "wait a beat", transcript)
      expect(later).to include("Tannery")                          # name still present
      expect(later).not_to include("The reek of lye and wet hide") # description dropped
      expect(later).not_to include("a vat of foul brown liquid")   # extras dropped
    end

    it "surfaces an `unresolved` field to narration when transcript.unresolved is set" do
      # Graceful terminal: a chain that dead-ends must tell narration the action
      # did NOT happen, so it renders a non-event instead of fabricating success.
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "(n)")
      loop_inst = described_class.new(adapter: adapter, context: context)
      transcript = Harness::Turn::Transcript.new(input: "walk into a forest", location_id: tavern.id)
      transcript.unresolved = "destination 'forest' not found"

      msg = loop_inst.send(:narration_user_message, "walk into a forest", transcript)
      expect(msg).to include("\"unresolved\"")
      expect(msg).to include("destination 'forest' not found")
    end

    it "omits `unresolved` from narration on a normal turn" do
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "(n)")
      loop_inst = described_class.new(adapter: adapter, context: context)
      transcript = Harness::Turn::Transcript.new(input: "look", location_id: tavern.id)
      msg = loop_inst.send(:narration_user_message, "look", transcript)
      expect(msg).not_to include("\"unresolved\"")
    end

    it "builds an out-of-character notice from the unresolved reason" do
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "(n)")
      loop_inst = described_class.new(adapter: adapter, context: context)
      notice = loop_inst.send(:unresolved_notice, "destination 'forest' not found")
      expect(notice).to match(/out of character/i)
      expect(notice).to include("destination 'forest' not found")
      expect(notice).to match(/rephras/i)
    end

    # The dice bracket line is rendered by Ruby from the real resolve, never
    # by the narration model (which fabricated rolls for movement/inspection).
    describe "dice bracket rendering (system-owned)" do
      let(:loop_inst) { described_class.new(adapter: Harness::LLM::FakeAdapter.new(reasoning: [], narration: "(n)"), context: context) }

      it "drops a fabricated bracket on a no-resolve turn (movement)" do
        prose = "[Transition — Movement 1 vs 0: success, decisive]\n\nYou step through the gate into the square."
        out = loop_inst.send(:compose_narration, prose, [ { "name" => "transition", "result" => {} } ])
        expect(out).to eq("You step through the gate into the square.")
      end

      it "discards the model's bracket and renders the authoritative one from the resolve result" do
        prose = "[Whatever — Bogus 1 vs 1: nonsense]\n\nYour blade bites deep."
        tcs = [ { "name" => "resolve", "result" => {
          "action" => "Heavy Strike", "ability_name" => "Heavy Strike", "stat" => "strength",
          "roll" => 17, "against" => 12, "outcome" => "success", "margin" => "clear"
        } } ]
        out = loop_inst.send(:compose_narration, prose, tcs)
        expect(out).to eq("[Heavy Strike — Heavy Strike 17 vs 12: success, clear]\n\nYour blade bites deep.")
      end

      it "labels with the capitalized stat when there's no ability_name, and flags criticals" do
        tcs = [ { "name" => "resolve", "result" => {
          "action" => "Climb the wall", "stat" => "strength", "roll" => 20, "against" => 10,
          "outcome" => "critical_success", "margin" => "decisive", "critical" => true
        } } ]
        expect(loop_inst.send(:resolve_bracket_lines, tcs))
          .to eq([ "[Climb the wall — Strength 20 vs 10: critical_success, decisive, critical]" ])
      end

      it "leaves bracketless prose untouched on a non-resolve turn" do
        out = loop_inst.send(:compose_narration, "The square is quiet under a grey sky.", [ { "name" => "query_scene" } ])
        expect(out).to eq("The square is quiet under a grey sky.")
      end
    end

    it "current_scene is empty {} shape when no scene active" do
      # Defensive: even without an active scene the field exists with
      # empty arrays so the prompt doesn't trip on a missing field.
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "(n)")
      loop_inst = described_class.new(adapter: adapter, context: context)
      loop_inst.instance_variable_get(:@scene_manager).instance_variable_set(:@active, nil)
      payload = loop_inst.send(:current_scene_payload)
      expect(payload).to eq({
        "present_characters" => [],
        "present_items"      => [],
        "present_corpses"    => [],
        "present_extras"     => []
      })
    end

    it "carries character appearance in the scene payload on establishing AND later turns" do
      Npc.create!(name: "Maren", subrole: "barkeep", location: tavern,
                  properties: { "appearance" => "broad-shouldered, burn-scarred forearms" })
      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "(n)")
      loop_inst = described_class.new(adapter: adapter, context: context)
      loop_inst.run_turn(input: "look around")

      [ true, false ].each do |establishing|
        payload = loop_inst.send(:current_scene_payload, include_extras: establishing)
        maren = payload["present_characters"].find { |c| c["name"] == "Maren" }
        expect(maren["appearance"]).to include("burn-scarred")
      end
    end
  end

  describe "budgets" do
    it "stops the reasoning loop after max_tool_calls" do
      script = Array.new(50) { { tool: "query_scene", args: {} } }
      adapter = Harness::LLM::FakeAdapter.new(reasoning: script, narration: "..")
      transcript = described_class.new(
        adapter: adapter, context: context, max_tool_calls: 3
      ).run_turn(input: "go")
      expect(transcript.tool_calls.size).to eq(3)
    end

    it "trims conversation history to history_cap after appending the turn" do
      history_cap = 2
      context.history << { "input" => "older", "narration" => "older" }
      context.history << { "input" => "old",   "narration" => "old" }

      adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "new")
      described_class.new(
        adapter: adapter, context: context, history_cap: history_cap
      ).run_turn(input: "now")

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
      run(reasoning: [], narration: "the bar is mostly empty")
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
      # narration recorded against the destination scene, NOT the origin.
      # This is the limbo fix: Turn N+1's recent_history reads the
      # warehouse's narrations, not an empty list (origin scene narrations
      # are wiped at exit).
      expect(context.active_scene.location).to eq(warehouse)
      expect(context.active_scene.narrations.last["narration"]).to eq("you arrive in the warehouse")

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
      broken_adapter = Class.new do
        def start_turn(system:, user:, tools:)
          raise "adapter exploded"
        end
        def complete(system:, user:)
          "never reached"
        end
      end.new

      expect {
        described_class.new(adapter: broken_adapter, context: context).run_turn(input: "x")
      }.to raise_error(/adapter exploded/)

      row = TurnLog.last
      expect(row.error).to match(/adapter exploded/)
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

    it "runs the round driver after reasoning fires start_combat and assembles round narration" do
      # Stub Termination so pre-flight returns nil (combat proceeds) but
      # end-of-round-1 returns :victory. Without two-step, the new pre-flight
      # check would catch :victory immediately and no round would run.
      call_count = 0
      allow(Harness::Combat::Termination).to receive(:evaluate) do
        call_count += 1
        call_count == 1 ? nil : :victory
      end

      # Pre-mark the player slot as exercised — simulates the reasoning
      # loop's combat resolve. Without this, the loop would YIELD at the
      # fresh player slot before any round ran. The FakeAdapter's scripted
      # start_combat call fires, then a custom hook marks tokens.
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

    it "yields when the reasoning loop fires start_combat but the player slot is fresh" do
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
      # Scene stays in combat; the next turn's reasoning loop will get
      # COMBAT_TOOLS and the player will drive their first slot.
      expect(context.active_scene&.in_combat?).to be(true)
      expect(context.scene_dirty).to be(false)
      # Bootstrap-yield with no rounds → regular narration step ran.
      expect(transcript.narration).to eq("regular narration body")
    end
  end
end
