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
    allow(Harness::Shadow::Planner).to receive(:plan_for).and_return(
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
  end

  it "falls to the agentic loop for the whole turn when the plan names an unbuilt runner" do
    stub_plan("movement")                                   # movement not in registry
    loop_obj, adapter = build_loop(registry: { "inspection" => Harness::Runners::Inspection.new })

    loop_obj.run_turn(input: "go to the docks")

    expect(adapter.reasoning_calls.size).to eq(1)          # agentic ran
  end

  it "falls to the agentic loop when the dispatcher can't produce a plan" do
    stub_plan(parse_error: "no JSON")
    loop_obj, adapter = build_loop(registry: { "inspection" => Harness::Runners::Inspection.new })

    loop_obj.run_turn(input: "???")

    expect(adapter.reasoning_calls.size).to eq(1)
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
      elsif prompt.include?("voice the NPC")
        { "dialogue_events" => [ { "actor_id" => barkeep.id, "summary" => "offers work", "prose" => "Aye, there's work for a steady hand." } ],
          "resolve_call" => nil, "ignorance" => [] }.to_json
      else
        "{}"
      end
    end

    adapter = Harness::LLM::FakeAdapter.new(reasoning: [], narration: "You step in and speak.")
    loop_obj = Harness::Turn::Loop.new(adapter: adapter, context: context, mode: :state_machine)

    transcript = nil
    expect { transcript = loop_obj.run_turn(input: "go to the tavern and ask the barkeep about work") }
      .to change(Event, :count).by_at_least(1)

    expect(player.reload.location_id).to eq(tavern.id)           # the move happened
    names = transcript.tool_calls.map { |t| t["name"] }
    expect(names).to include("transition", "propose_event")      # both runners committed
    expect(adapter.reasoning_calls).to be_empty                  # never touched the agentic loop
    dialogue = Event.where(scope: "local").last
    expect(dialogue.event_participants.pluck(:character_id)).to include(barkeep.id, player.id)
  end

  it "skips the dispatcher entirely in :agentic mode" do
    expect(Harness::Shadow::Planner).not_to receive(:plan_for)
    loop_obj, adapter = build_loop(
      registry: { "inspection" => Harness::Runners::Inspection.new }, mode: :agentic
    )

    loop_obj.run_turn(input: "anything")

    expect(adapter.reasoning_calls.size).to eq(1)
  end
end
