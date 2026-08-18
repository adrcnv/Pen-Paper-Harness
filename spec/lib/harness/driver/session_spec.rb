require "rails_helper"

RSpec.describe Harness::Driver::Session do
  let(:city)   { Location.create!(name: "Saltmere", x: 1.0, y: 1.0) }
  let(:player) { Player.create!(name: "Tester", location: city, character_class: "fighter", level: 1) }

  # Planner routes everything to inspection; inspection's prose call gets a
  # flat line back. Enough LLM to drive one real turn end to end.
  let(:stub) {
    StubLLM.new { |prompt|
      if prompt.include?("\"plan\"") || prompt.include?("PLAN")
        { "reasoning" => "look", "plan" => [ { "reason" => "look around", "runner" => "inspection", "args" => {} } ] }.to_json
      else
        "The room sits quiet."
      end
    }
  }

  let(:session) { described_class.new(seed: 7, grunt: stub, nuance: stub, logger: Logger.new(IO::NULL)) }

  after { Harness::Turn::Receipt.disable! }

  it "refuses to boot outside the scenario/test environments" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    expect { described_class.new(grunt: stub, nuance: stub) }.to raise_error(/play save/)
  end

  it "continue! raises without a player, boots with one" do
    expect { session.continue! }.to raise_error(/no player/)
    player
    expect(session.continue!).to eq(session)
    expect(session.player_location).to eq(city)
  end

  it "plays a headless turn and returns narration plus the receipt" do
    player
    session.continue!
    result = session.play("look around")

    expect(result).to include("narration", "game_time", "location", "receipt")
    expect(result["location"]).to eq("Saltmere")
    expect(result["receipt"]).to be_a(Hash)
    expect(result["receipt"]["runners"]).to include("inspection")
    expect(result["receipt"]["input"]).to eq("look around")
  end

  it "derives per-turn seeds from the session seed (reproducible run plan)" do
    a = Random.new(7)
    b = Random.new(7)
    expect(Array.new(3) { a.rand(2**31) }).to eq(Array.new(3) { b.rand(2**31) })
  end
end
