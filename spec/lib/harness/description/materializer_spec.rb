require "rails_helper"

RSpec.describe Harness::Description::Materializer do
  let(:city)   { Location.create!(name: "Saltmere") }
  let(:logger) { Logger.new(IO::NULL) }

  let(:npc) {
    Npc.create!(
      name: "Marek", subrole: "captain", location: city,
      level: 5,
      strength: 14, dexterity: 12, constitution: 13,
      intelligence: 11, wisdom: 12, charisma: 13
    )
  }

  def good_output(personality: "Steady-handed and slow to anger; speaks plainly to those he respects.",
                  appearance: "Broad-shouldered, with weathered hands and a faded scar along his left jaw.")
    { "personality" => personality, "appearance" => appearance }.to_json
  end

  it "writes personality + appearance into character.properties" do
    llm = StubLLM.new { |_prompt| good_output }
    described_class.new(llm_client: llm, logger: logger).materialize!(npc)

    npc.reload
    expect(npc.properties["personality"]).to start_with("Steady-handed")
    expect(npc.properties["appearance"]).to include("scar")
  end

  it "preserves unrelated property keys" do
    npc.update!(properties: { "faction_id" => 7, "appearance_intent" => "looking for the player" })
    llm = StubLLM.new { |_prompt| good_output }
    described_class.new(llm_client: llm, logger: logger).materialize!(npc)

    npc.reload
    expect(npc.properties["faction_id"]).to eq(7)
    expect(npc.properties["appearance_intent"]).to eq("looking for the player")
    expect(npc.properties["personality"]).to be_present
    expect(npc.properties["appearance"]).to be_present
  end

  it "is a no-op for Player rows" do
    player = Player.create!(name: "Hero", location: city)
    called = false
    llm = StubLLM.new { |_prompt| called = true; good_output }

    described_class.new(llm_client: llm, logger: logger).materialize!(player)
    expect(called).to be(false)
    expect(player.reload.properties).not_to have_key("personality")
  end

  it "passes prose_context through to the user message" do
    seen_user = nil
    llm = StubLLM.new { |prompt|
      seen_user = prompt
      good_output
    }
    described_class.new(llm_client: llm, logger: logger).materialize!(
      npc, prose_context: "lost his son to a bolt at the Battle of Blue Roses"
    )
    expect(seen_user).to include("lost his son to a bolt at the Battle of Blue Roses")
  end

  it "passes scenario_seed through to the user message" do
    seen_user = nil
    llm = StubLLM.new { |prompt|
      seen_user = prompt
      good_output
    }
    described_class.new(llm_client: llm, logger: logger).materialize!(
      npc, scenario_seed: "SCENARIO: This person is a retired adept of dangerous craft."
    )
    expect(seen_user).to include("SCENARIO: This person is a retired adept")
  end

  it "exposes the character's stats + level to the LLM (downstream conditioning)" do
    seen_user = nil
    llm = StubLLM.new { |prompt|
      seen_user = prompt
      good_output
    }
    described_class.new(llm_client: llm, logger: logger).materialize!(npc)

    expect(seen_user).to include('"level"')
    expect(seen_user).to include('"strength"')
    expect(seen_user).to include('"charisma"')
  end

  it "retries on invalid output, then accepts" do
    attempt = 0
    llm = StubLLM.new { |_prompt|
      attempt += 1
      attempt == 1 ? "not json" : good_output
    }
    described_class.new(llm_client: llm, logger: logger).materialize!(npc)
    expect(attempt).to eq(2)
    expect(npc.reload.properties["personality"]).to be_present
  end

  it "raises after exhausting retries on persistent invalid output" do
    llm = StubLLM.new { |_prompt| '{"personality": "x"}' }  # too short, missing appearance
    expect {
      described_class.new(llm_client: llm, logger: logger, max_retries: 1).materialize!(npc)
    }.to raise_error(Harness::Description::Hydrator::InvalidOutput)
  end

  describe "cache prefix stability" do
    it_behaves_like "stable cache prefix" do
      let(:llm) {
        attempt = 0
        StubLLM.new do |_prompt|
          attempt += 1
          attempt == 1 ? '{"personality": "x"}' : good_output  # repair retry triggers
        end
      }

      let(:npc1) { npc }
      let(:npc2) {
        Npc.create!(
          name: "Sigrid", subrole: "scholar", location: city, level: 8,
          strength: 9, dexterity: 11, constitution: 10,
          intelligence: 17, wisdom: 14, charisma: 12,
          properties: { "appearance_intent" => "wants to test the player's literacy" }
        )
      }

      let(:exercise) {
        -> {
          described_class.new(llm_client: llm, logger: logger, max_retries: 1).materialize!(npc1)
          described_class.new(llm_client: llm, logger: logger).materialize!(npc2)
        }
      }
    end
  end
end
