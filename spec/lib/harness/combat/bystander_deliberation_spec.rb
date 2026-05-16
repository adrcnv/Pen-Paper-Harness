require "rails_helper"

RSpec.describe Harness::Combat::BystanderDeliberation do
  let(:loc) { Location.create!(name: "Tavern") }
  let(:patron) do
    Npc.create!(
      name: "Old Pete",
      subrole: "patron",
      location: loc,
      properties: { "personality" => "cautious", "following_player" => false }
    )
  end
  let(:sides) { [{ "name" => "player_party", "members" => [ 1 ] }, { "name" => "marauders", "members" => [ 7 ] }] }
  let(:initiator) { { "id" => 1, "name" => "Mud", "side" => "player_party" } }

  it "returns a valid decision when LLM responds cleanly" do
    llm = StubLLM.new { '{"decision": "watch", "reason": "frozen at the bar"}' }
    out = described_class.run(character: patron, sides: sides, initiator: initiator, inciting_beat: "Mud drew steel", llm: llm)
    expect(out).to eq("decision" => "watch", "reason" => "frozen at the bar")
  end

  it "strips ```json fences" do
    llm = StubLLM.new { "```json\n{\"decision\": \"flee\", \"reason\": \"ran for the door\"}\n```" }
    out = described_class.run(character: patron, sides: sides, initiator: initiator, inciting_beat: "Mud drew steel", llm: llm)
    expect(out["decision"]).to eq("flee")
  end

  it "falls back to flee on malformed JSON" do
    llm = StubLLM.new { "I think this character would probably flee." }
    out = described_class.run(character: patron, sides: sides, initiator: initiator, inciting_beat: "Mud drew steel", llm: llm)
    expect(out).to eq(described_class::DEFAULT_FALLBACK)
  end

  it "falls back to flee on unknown decision" do
    llm = StubLLM.new { '{"decision": "negotiate", "reason": "tries to talk it down"}' }
    out = described_class.run(character: patron, sides: sides, initiator: initiator, inciting_beat: "Mud drew steel", llm: llm)
    expect(out["decision"]).to eq("flee")
  end

  it "falls back to flee when LLM is nil" do
    out = described_class.run(character: patron, sides: sides, initiator: initiator, inciting_beat: "Mud drew steel", llm: nil)
    expect(out).to eq(described_class::DEFAULT_FALLBACK)
  end

  it "falls back to flee on LLM raise" do
    llm = Object.new
    def llm.complete(**); raise "boom"; end
    out = described_class.run(character: patron, sides: sides, initiator: initiator, inciting_beat: "Mud drew steel", llm: llm)
    expect(out).to eq(described_class::DEFAULT_FALLBACK)
  end

  it "passes character context (subrole, personality, follower flag) into the user payload" do
    captured_user = nil
    llm = StubLLM.new { |prompt| captured_user = prompt; '{"decision": "watch", "reason": "stays"}' }
    described_class.run(character: patron, sides: sides, initiator: initiator, inciting_beat: "Mud drew steel", llm: llm)
    expect(captured_user).to include("Old Pete")
    expect(captured_user).to include("patron")
    expect(captured_user).to include("cautious")
    expect(captured_user).to include("Mud drew steel")
  end

  it "uses cache-stable system across calls" do
    llm = StubLLM.new(strict: true) { '{"decision": "flee", "reason": "ran"}' }
    other_loc = Location.create!(name: "Square")
    other = Npc.create!(name: "Different", subrole: "guard", location: other_loc, properties: { "personality" => "aggressive" })
    described_class.run(character: patron, sides: sides, initiator: initiator, inciting_beat: "alpha", llm: llm)
    described_class.run(character: other,  sides: sides, initiator: initiator, inciting_beat: "beta",  llm: llm)
    expect { llm.assert_stable_system! }.not_to raise_error
  end
end
