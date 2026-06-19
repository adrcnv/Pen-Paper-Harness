require "rails_helper"

RSpec.describe Harness::Runners::Conversation do
  let(:tavern) { Location.create!(name: "The Drowned Rat") }
  let!(:player) { Player.create!(name: "Hero", location: tavern) }
  let!(:barkeep) { Npc.create!(name: "Tomas", subrole: "barkeep", location: tavern) }

  def context_with(&block)
    Harness::Turn::Context.new(player_location: tavern, llm_nuance: StubLLM.new(&block), game_time: 100)
  end

  def step(intent = "ask the barkeep") = Harness::Dispatcher::Step.new(runner: "conversation", intent: intent, args: {})

  it "commits one propose_event per responding NPC, player tagged as participant" do
    ctx = context_with do
      { "dialogue_events" => [ { "actor_id" => barkeep.id, "summary" => "greets the player", "prose" => "Aye, what'll it be?" } ],
        "resolve_call" => nil, "ignorance" => [] }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    expect {
      @outcome = described_class.new.run(context: ctx, scene: scene, input: "hello barkeep", step: step)
    }.to change(Event, :count).by(1)

    expect(@outcome.status).to eq(:ok)
    names = @outcome.tool_calls.map { |t| t["name"] }
    expect(names).to include("query_events", "propose_event")
    ev = Event.last
    pids = ev.event_participants.pluck(:character_id)
    expect(pids).to include(barkeep.id, player.id)
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
