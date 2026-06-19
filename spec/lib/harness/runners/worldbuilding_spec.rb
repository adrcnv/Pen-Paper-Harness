require "rails_helper"

RSpec.describe Harness::Runners::Worldbuilding do
  let(:city)    { Location.create!(name: "Oakenford") }
  let!(:player) { Player.create!(name: "Hero", location: city) }
  let(:step)    { Harness::Dispatcher::Step.new(runner: "worldbuilding", intent: "find a tavern", args: {}) }

  def context_with(&block)
    Harness::Turn::Context.new(player_location: city, llm_nuance: StubLLM.new(&block), game_time: 100)
  end

  it "creates a sublocation + character (the CREATE chain) for an implied amenity" do
    ctx = context_with do
      { "location"  => { "type" => "sublocation", "name" => "The Drowned Rat", "description" => "a dockside tavern", "connection" => "every port has a tavern" },
        "character" => { "subrole" => "barkeep", "name" => "Tomas", "description" => "burly", "connection" => "runs the tavern" },
        "item" => nil, "kickoff" => nil }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = nil
    expect { outcome = described_class.new.run(context: ctx, scene: scene, input: "is there a tavern?", step: step) }
      .to change(Location, :count).by(1).and change(Npc, :count).by(1)

    expect(outcome.status).to eq(:ok)
    names = outcome.tool_calls.map { |t| t["name"] }
    expect(names).to include("propose_location", "propose_character")
    new_loc = Location.where(parent_id: city.id).last
    expect(Npc.last.location_id).to eq(new_loc.id) # character placed at the new sublocation
  end

  it "deflects (no-op, no creation) when the model returns an all-null spec" do
    ctx = context_with { { "location" => nil, "character" => nil, "item" => nil, "kickoff" => nil }.to_json }
    scene = Harness::Tools::QueryScene.build(ctx)

    expect { @outcome = described_class.new.run(context: ctx, scene: scene, input: "is the legendary archmage here?", step: step) }
      .not_to change(Location, :count)
    expect(@outcome.status).to eq(:ok)
    expect(@outcome.tool_calls).to be_empty
  end

  it "re-dispatches (no crash) on unparseable emit" do
    ctx = context_with { "not json" }
    scene = Harness::Tools::QueryScene.build(ctx)
    outcome = described_class.new.run(context: ctx, scene: scene, input: "make a thing", step: step)
    expect(outcome.status).to eq(:redispatch)
  end
end
