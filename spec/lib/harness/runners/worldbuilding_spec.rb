require "rails_helper"

RSpec.describe Harness::Runners::Worldbuilding do
  let(:city)    { Location.create!(name: "Oakenford") }
  let!(:tavern) { Location.create!(name: "the Alehouse", parent: city, description: "A low-beamed taproom.") }
  let!(:player) { Player.create!(name: "Hero", location: city) }
  let(:step)    { Harness::Dispatcher::Step.new(runner: "worldbuilding", intent: "find a tavern", args: {}) }

  def ctx(&block) = Harness::Turn::Context.new(player_location: city, llm_grunt: StubLLM.new(&block), game_time: 100)
  def run(input, context) = described_class.new.run(context: context, scene: Harness::Tools::QueryScene.build(context), input: input, step: step)

  it "answers with the room the town has, as a discovery record, creating nothing" do
    c = ctx { %({"reasoning": "the tavern is the Alehouse", "is": "listed_room", "room_id": #{tavern.id}, "scenery": null}) }
    outcome = nil
    expect { outcome = run("is there a tavern here?", c) }.not_to change { [ Location.count, Npc.count ] }
    expect(outcome.status).to eq(:ok)
    tc = outcome.tool_calls.first
    expect(tc["name"]).to eq("resolve_location")
    expect(tc["result"]).to include("location_id" => tavern.id, "name" => "the Alehouse", "status" => "linked", "type" => "sublocation")
    expect(tc["args"]).to include("description" => "A low-beamed taproom.")
  end

  it "mints a scenery kind once when that is what was asked for" do
    c = ctx { %({"reasoning": "somewhere out of sight", "is": "scenery", "room_id": null, "scenery": "alley"}) }
    outcome = nil
    expect { outcome = run("find a quiet back alley", c) }.to change(Location, :count).by(1)
    expect(outcome.tool_calls.first["result"]).to include("status" => "minted")
    expect(Location.order(:id).last.parent).to eq(city)
    expect { run("some alley to talk in", c) }.not_to change(Location, :count)
  end

  it "says there is nothing of the kind, and builds none, when the town has not got it" do
    c = ctx { %({"reasoning": "no smithy is listed", "is": "neither", "room_id": null, "scenery": null}) }
    outcome = nil
    expect { outcome = run("is there a smith?", c) }.not_to change { [ Location.count, Npc.count ] }
    expect(outcome.status).to eq(:ok)
    expect(outcome.null_line).to be_nil   # an answer, rendered as a record — never swallowed beside a voicing
    expect(outcome.tool_calls.first).to include("name" => "resolve_location", "result" => { "status" => "refused", "settlement" => "Oakenford" })
  end

  it "has no author to redispatch to: an unreadable judge answer is a refusal" do
    expect(run("make a thing", ctx { "not json" }).status).to eq(:ok)
  end
end
