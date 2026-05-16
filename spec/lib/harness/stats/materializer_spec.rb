require "rails_helper"

RSpec.describe Harness::Stats::Materializer do
  let(:city)   { Location.create!(name: "Saltmere") }
  let(:logger) { Logger.new(IO::NULL) }

  def good_output(level: 1, character_class: "commoner")
    {
      "level" => level, "character_class" => character_class,
      "strength" => 12, "dexterity" => 10, "constitution" => 14,
      "intelligence" => 9, "wisdom" => 11, "charisma" => 13
    }.to_json
  end

  it "populates all six stat columns on a fully-nil NPC" do
    npc = Npc.create!(name: "Maren", subrole: "barkeep", location: city)
    llm = StubLLM.new { |_prompt| good_output }
    described_class.new(llm_client: llm, logger: logger).materialize_if_needed(npc)

    npc.reload
    expect(npc.strength).to eq(12)
    expect(npc.constitution).to eq(14)
    expect(npc.charisma).to eq(13)
  end

  it "is a no-op when all stats are already set (no LLM call)" do
    npc = Npc.create!(
      name: "Maren", subrole: "barkeep", location: city,
      strength: 10, dexterity: 10, constitution: 10,
      intelligence: 10, wisdom: 10, charisma: 10
    )
    called = false
    llm = StubLLM.new { |_prompt| called = true; good_output }

    described_class.new(llm_client: llm, logger: logger).materialize_if_needed(npc)
    expect(called).to be(false)
  end

  it "fires if ANY stat column is nil" do
    npc = Npc.create!(
      name: "Maren", subrole: "barkeep", location: city,
      strength: 10, dexterity: 10, constitution: 10,
      intelligence: 10, wisdom: 10  # charisma nil
    )
    called = false
    llm = StubLLM.new { |_prompt| called = true; good_output }

    described_class.new(llm_client: llm, logger: logger).materialize_if_needed(npc)
    expect(called).to be(true)
    expect(npc.reload.charisma).to eq(13)
  end

  it "is a no-op for Player rows" do
    player = Player.create!(name: "Hero", location: city)
    called = false
    llm = StubLLM.new { |_prompt| called = true; good_output }

    described_class.new(llm_client: llm, logger: logger).materialize_if_needed(player)
    expect(called).to be(false)
    expect(player.reload.strength).to be_nil
  end

  it "retries on invalid output, then accepts" do
    attempt = 0
    llm = StubLLM.new { |_prompt|
      attempt += 1
      attempt == 1 ? "not json" : good_output
    }
    npc = Npc.create!(name: "Maren", subrole: "barkeep", location: city)
    described_class.new(llm_client: llm, logger: logger).materialize_if_needed(npc)
    expect(attempt).to eq(2)
    expect(npc.reload.strength).to eq(12)
  end

  it "raises after exhausting retries on persistent invalid output" do
    llm = StubLLM.new { |_prompt| '{"strength": 999}' }
    npc = Npc.create!(name: "Maren", subrole: "barkeep", location: city)
    expect {
      described_class.new(llm_client: llm, logger: logger, max_retries: 1).materialize_if_needed(npc)
    }.to raise_error(Harness::Stats::Hydrator::InvalidOutput)
  end

  describe "cache prefix stability" do
    it_behaves_like "stable cache prefix" do
      let(:llm) {
        attempt = 0
        StubLLM.new do |_prompt|
          attempt += 1
          if attempt == 1
            '{"strength": 999}'  # out-of-range; triggers repair retry
          else
            { "level" => 1, "character_class" => "commoner",
              "strength" => 10, "dexterity" => 10, "constitution" => 10,
              "intelligence" => 10, "wisdom" => 10, "charisma" => 10 }.to_json
          end
        end
      }

      let(:exercise) {
        npc1 = Npc.create!(name: "Maren", subrole: "barkeep",  location: city)
        npc2 = Npc.create!(name: "Korr",    subrole: "stranger", location: city,
                           properties: { "personality" => "guarded", "background" => "ex-soldier" })
        -> {
          described_class.new(llm_client: llm, logger: logger, max_retries: 1).materialize_if_needed(npc1)
          described_class.new(llm_client: llm, logger: logger).materialize_if_needed(npc2)
        }
      }
    end
  end
end
