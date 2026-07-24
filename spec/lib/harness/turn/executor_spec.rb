require "rails_helper"

# Exercises the state-machine executor in Turn::Loop: dispatch → chain →
# runners, with stub runners to drive chain control (combat terminator,
# re-dispatch cap) and a stubbed planner to control the plan.
RSpec.describe "Harness::Turn::Loop state machine" do
  let(:tavern) { Location.create!(name: "Tavern") }
  let!(:player) { Player.create!(name: "Hero", subrole: "adventurer", location: tavern) }
  let(:context) { Harness::Turn::Context.new(player_location: tavern, game_time: 100) }

  # Records invocations; returns a configured Outcome (last repeats).
  class StubRunner < Harness::Runners::Base
    attr_reader :calls
    def initialize(outcomes:)
      # NB: Array(struct) explodes a Struct into its fields — wrap explicitly.
      @outcomes = outcomes.is_a?(Array) ? outcomes : [ outcomes ]
      @calls = 0
    end

    def run(**)
      @calls += 1
      @outcomes[[ @calls - 1, @outcomes.size - 1 ].min]
    end
  end

  def build_loop(registry:, mode: :state_machine, narration: "(n)")
    adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: narration)
    [ Harness::Turn::Loop.new(adapter: adapter, context: context, registry: registry, mode: mode), adapter ]
  end

  def stub_plan(*runner_labels, parse_error: nil)
    allow(Harness::Planner).to receive(:plan_for).and_return(
      "plan"        => parse_error ? nil : runner_labels.map { |r| { "runner" => r, "reason" => "do #{r}", "args" => {} } },
      "parse_error" => parse_error,
      "raw"         => "",
      "duration_ms" => 1,
      "model"       => "fake",
      "world"       => {}
    )
  end

  it "routes a built single-runner plan through the chain (no agentic)" do
    stub_plan("inspection")
    loop_obj, adapter = build_loop(registry: { "inspection" => Harness::Runners::Inspection.new })

    transcript = loop_obj.run_turn(input: "look around")

    expect(transcript.tool_calls.map { |t| t["name"] }).to eq([ "query_scene" ])
    expect(adapter.reasoning_calls).to be_empty            # agentic loop did NOT run
    expect(transcript.narration).to eq("(n)")
    expect(transcript.runners_ran).to eq([ "inspection" ]) # the executor records which runner ran
  end

  # The agentic loop is no longer routable (vaporized 2026-07-24) — every
  # failure shape degrades to a safe inspection step instead, and the loop
  # survives only behind the explicit :agentic mode.
  it "degrades an unknown-runner step to inspection instead of the agentic loop" do
    stub_plan("movement")                                   # movement not in registry
    loop_obj, adapter = build_loop(registry: { "inspection" => Harness::Runners::Inspection.new })

    transcript = loop_obj.run_turn(input: "go to the docks")

    expect(adapter.reasoning_calls).to be_empty            # agentic did NOT run
    expect(transcript.runners_ran).to eq([ "inspection" ])
  end

  it "degrades a failed plan to a single inspection step carrying the raw input" do
    stub_plan(parse_error: "no JSON")
    loop_obj, adapter = build_loop(registry: { "inspection" => Harness::Runners::Inspection.new })

    transcript = loop_obj.run_turn(input: "???")

    expect(adapter.reasoning_calls).to be_empty
    expect(transcript.runners_ran).to eq([ "inspection" ])
  end

  it "treats :combat as a hard terminator and aborts remaining steps" do
    combat_step = StubRunner.new(outcomes: Harness::Runners::Outcome.new(status: :combat))
    after_step  = StubRunner.new(outcomes: Harness::Runners::Outcome.new(status: :ok))
    stub_plan("boom", "after")
    loop_obj, = build_loop(registry: { "boom" => combat_step, "after" => after_step })

    loop_obj.run_turn(input: "attack then chat")

    expect(combat_step.calls).to eq(1)
    expect(after_step.calls).to eq(0)                       # chain aborted at combat
  end

  it "bounds re-dispatch and hard-stops after REDISPATCH_CAP" do
    stale = StubRunner.new(outcomes: Harness::Runners::Outcome.new(status: :redispatch))
    stub_plan("stale")                                     # every re-plan returns [stale]
    loop_obj, = build_loop(registry: { "stale" => stale })

    loop_obj.run_turn(input: "do the impossible")

    # initial run + REDISPATCH_CAP re-dispatches, then hard stop
    expect(stale.calls).to eq(Harness::Turn::Loop::REDISPATCH_CAP + 1)
  end

  it "runs a movement→conversation chain: conversation sees the NPC only after the move (world handoff)" do
    city    = Location.create!(name: "Oakenford")
    tavern  = Location.create!(name: "The Drowned Rat", parent_id: city.id)
    barkeep = Npc.create!(name: "Tomas", subrole: "barkeep", location: tavern)
    player.update!(location: city)
    context.player_location = city

    # One StubLLM serves dispatcher + both runners, branching on the prompt.
    # llm_grunt left nil → scene-entry materializers skip (no spurious NPCs).
    context.llm_nuance = StubLLM.new do |prompt|
      if prompt.include?("PLANNER")
        { "plan" => [
          { "runner" => "movement",     "reason" => "go to the tavern" },
          { "runner" => "conversation", "reason" => "ask the barkeep about work" }
        ] }.to_json
      elsif prompt.include?("route a player's MOVEMENT")
        { "action" => "transition", "target_id" => tavern.id, "place_name" => nil }.to_json
      elsif prompt.include?("voice ONE character")
        { "speak" => true,
          "dialogue" => { "summary" => "offers work", "prose" => "Aye, there's work for a steady hand." } }.to_json
      else
        "{}"
      end
    end

    adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "You step in and speak.")
    loop_obj = Harness::Turn::Loop.new(adapter: adapter, context: context, mode: :state_machine)

    transcript = loop_obj.run_turn(input: "go to the tavern and ask the barkeep about work")

    expect(player.reload.location_id).to eq(tavern.id)           # the move happened
    names = transcript.tool_calls.map { |t| t["name"] }
    expect(names).to include("transition", "propose_event")      # move committed; conversation staged a line
    expect(adapter.reasoning_calls).to be_empty                  # never touched the agentic loop
    # The handoff proof: the staged dialogue names the barkeep, who only became
    # visible to conversation AFTER the move materialized the tavern scene.
    # (Dialogue is staged, not persisted — so we read it off the tool_call.)
    say = transcript.tool_calls.find { |t| t["name"] == "propose_event" && t.dig("result", "staged") }
    pids = Array(say&.dig("args", "participants")).map { |p| p["character_id"] }
    expect(pids).to include(barkeep.id, player.id)
    # The conversation runner ran this turn — the signal initiative gates on so
    # it doesn't pile an unprompted beat on top of dialogue the player just had.
    expect(transcript.runners_ran).to include("conversation")
  end

  # Post-rework smoke test: a contested action must ROLL inside its runner (the
  # standalone dice runner is gone). Drives dispatcher → environment runner →
  # resolve → real d20 engine → authoritative bracket, all in state_machine mode.
  it "rolls a contested action through the environment runner and renders the bracket" do
    context.llm_nuance = StubLLM.new do |prompt|
      if prompt.include?("PLANNER")
        { "plan" => [ { "runner" => "environment", "reason" => "force the door" } ] }.to_json
      elsif prompt.include?("PHYSICAL INTERACTION")
        { "action" => "force the stuck door",
          "roll" => { "stat" => "strength", "difficulty" => "moderate" },
          "time_minutes" => 2, "yields_item" => nil, "location_change" => nil }.to_json
      else
        "{}"
      end
    end

    adapter  = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "You heave at the door.")
    loop_obj = Harness::Turn::Loop.new(adapter: adapter, context: context, mode: :state_machine)

    transcript = loop_obj.run_turn(input: "force the door open")

    resolve = transcript.tool_calls.find { |t| t["name"] == "resolve" }
    expect(resolve).not_to be_nil, "environment runner did not fire resolve — dice never rolled"
    expect(resolve["result"]["outcome"]).to be_present              # the engine actually resolved
    expect(resolve["result"]).to include("roll", "against")          # real d20 numbers exist
    expect(adapter.reasoning_calls).to be_empty                      # state machine, not agentic
    expect(transcript.narration).to match(/\[force the stuck door .* Strength \d+ vs \d+/) # bracket rendered
  end

  # Post-rework smoke test: the STATE-MACHINE combat seam — dispatcher → combat
  # runner → start_combat → :combat terminator → Turn::Loop hands off to
  # Combat::Loop. (Combat::Loop's internals are covered elsewhere; this proves
  # the state_machine ENTRY into it, which the rework touched and never tested.)
  # Termination is forced to settle pre-flight so the driver returns without
  # needing NPC-turn stubs.
  it "enters combat through the combat runner and hands off to the round driver" do
    vek = Npc.create!(name: "Vek", subrole: "marauder", location: tavern, current_hp: 18, max_hp: 18)
    allow(Harness::Combat::Termination).to receive(:evaluate).and_return(:victory)

    context.llm_nuance = StubLLM.new do |prompt|
      if prompt.include?("PLANNER")
        { "plan" => [ { "runner" => "combat", "reason" => "attack Vek" } ] }.to_json
      elsif prompt.include?("set up the START of a fight")
        { "player_side" => [ player.id ], "enemy_side" => [ vek.id ],
          "inciting_beat" => "the player draws steel on Vek" }.to_json
      else
        "{}"
      end
    end

    adapter  = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "(combat owns narration)")
    loop_obj = Harness::Turn::Loop.new(adapter: adapter, context: context, mode: :state_machine)

    transcript = loop_obj.run_turn(input: "attack Vek")

    start_combat = transcript.tool_calls.find { |t| t["name"] == "start_combat" }
    expect(start_combat).not_to be_nil, "combat runner did not fire start_combat"
    expect(start_combat["result"]["error"]).to be_nil, "start_combat errored: #{start_combat['result']['error']}"
    expect(transcript.combat).to be_a(Harness::Combat::Loop::Result)   # the driver actually ran
    expect(transcript.combat.end_reason).to eq(:victory)
    expect(adapter.reasoning_calls).to be_empty                        # state machine, not agentic
  end

  it "skips the dispatcher entirely in :agentic mode" do
    expect(Harness::Planner).not_to receive(:plan_for)
    loop_obj, adapter = build_loop(
      registry: { "inspection" => Harness::Runners::Inspection.new }, mode: :agentic
    )

    loop_obj.run_turn(input: "anything")

    expect(adapter.reasoning_calls.size).to eq(1)
  end
end
