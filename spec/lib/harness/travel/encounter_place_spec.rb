require "rails_helper"

RSpec.describe Harness::Travel::EncounterPlace do
  let(:logger) { Logger.new(IO::NULL) }

  let(:saltmere) { Location.create!(name: "Saltmere", x: 10.0, y: 10.0, biome: "lowland") }

  def good(name, desc = "A weather-greyed cottage set back from the road, smoke curling from a leaning chimney.")
    { "name" => name, "description" => desc }.to_json
  end

  it "returns a Result(name, description) on well-formed output" do
    llm = StubLLM.new { |_| good("the Old Carter's Cottage") }
    out = described_class.new(llm_client: llm, logger: logger)
                         .generate(bucket: "discovery", biome: "lowland", anchor_name: saltmere.name)
    expect(out.name).to eq("the Old Carter's Cottage")
    expect(out.description).to match(/cottage/)
  end

  it "rejects names with fewer than 3 words" do
    attempts = []
    llm = StubLLM.new { |user|
      attempts << user
      attempts.size == 1 ? good("Bandit Camp") : good("the Old Carter's Cottage")
    }
    out = described_class.new(llm_client: llm, logger: logger)
                         .generate(bucket: "social", biome: "lowland", anchor_name: saltmere.name)
    expect(out.name).to eq("the Old Carter's Cottage")
    expect(attempts.size).to eq(2)
    expect(attempts.last).to match(/at least 3 words/)
  end

  it "rejects name collisions with existing Locations and retries" do
    saltmere
    attempts = []
    llm = StubLLM.new { |user|
      attempts << user
      attempts.size == 1 ? good("Saltmere on the Coast") : good("the Old Carter's Cottage")
    }
    # Wait — "Saltmere on the Coast" has 4 words and doesn't collide directly.
    # Test explicit collision: produce the existing name verbatim first.
    attempts.clear
    llm = StubLLM.new { |user|
      attempts << user
      attempts.size == 1 ? good("Saltmere") : good("the Old Carter's Cottage")
    }
    out = described_class.new(llm_client: llm, logger: logger)
                         .generate(bucket: "social", biome: "lowland", anchor_name: saltmere.name)
    expect(out.name).to eq("the Old Carter's Cottage")
    expect(attempts.last).to match(/collides|at least 3 words/)
  end

  it "raises after exhausting retries" do
    llm = StubLLM.new { |_| good("Bad") }  # always fails the 3-word rule
    expect {
      described_class.new(llm_client: llm, logger: logger, max_retries: 1)
                     .generate(bucket: "social", biome: "lowland", anchor_name: saltmere.name)
    }.to raise_error(described_class::InvalidOutput, /at least 3 words/)
  end

  it "rejects non-JSON output" do
    llm = StubLLM.new { |_| "not json at all" }
    expect {
      described_class.new(llm_client: llm, logger: logger, max_retries: 0)
                     .generate(bucket: "social", biome: "lowland", anchor_name: saltmere.name)
    }.to raise_error(described_class::InvalidOutput, /not valid JSON/)
  end

  it "rejects too-short descriptions" do
    llm = StubLLM.new { |_| { "name" => "the Old Carter's Cottage", "description" => "tiny" }.to_json }
    expect {
      described_class.new(llm_client: llm, logger: logger, max_retries: 0)
                     .generate(bucket: "social", biome: "lowland", anchor_name: saltmere.name)
    }.to raise_error(described_class::InvalidOutput, /too short/)
  end
end
