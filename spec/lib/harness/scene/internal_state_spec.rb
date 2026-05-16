require "rails_helper"

RSpec.describe Harness::Scene::InternalState do
  let(:tavern) { Location.create!(name: "Tavern") }
  let(:logger) { Logger.new(IO::NULL) }

  let(:maren) { Npc.create!(name: "Maren", subrole: "barkeep", location: tavern) }
  let(:korr)    { Npc.create!(name: "Korr",    subrole: "stranger", location: tavern) }

  def good_output(names, extras: [], agenda: nil)
    body = {
      "internal_states" => names.each_with_object({}) { |n, h|
        h[n] = "#{n} is in some plausible internal mood right now today."
      },
      "extras" => extras
    }
    if agenda
      body["agenda"] = agenda
    end
    body.to_json
  end

  it "still calls the LLM when no NPCs are present (extras-only mode for empty populated places)" do
    # Empty INPUT.characters → internal_states is {}, but extras can still be
    # painted so a city/market/inn with no character rows yet feels populated.
    llm = StubLLM.new { |_p| { "internal_states" => {}, "extras" => [ "a vendor setting up a stall at the edge of the circle" ] }.to_json }
    out = described_class.new(llm_client: llm, logger: logger).generate(location: tavern, characters: [])
    expect(out.internal_state).to eq({})
    expect(out.extras).to eq([ "a vendor setting up a stall at the edge of the circle" ])
  end

  it "still calls the LLM when all present characters are Players (extras only)" do
    player = Player.create!(name: "Hero", location: tavern)
    llm = StubLLM.new { |_p| { "internal_states" => {}, "extras" => [] }.to_json }
    out = described_class.new(llm_client: llm, logger: logger).generate(location: tavern, characters: [ player ])
    expect(out.internal_state).to eq({})
    expect(out.extras).to eq([])
  end

  it "filters out Players when mixed with NPCs and only generates for NPCs" do
    player = Player.create!(name: "Hero", location: tavern)
    maren  # ensure persisted

    captured_prompt = nil
    llm = StubLLM.new { |user|
      captured_prompt = user
      good_output([ "Maren" ])
    }
    out = described_class.new(llm_client: llm, logger: logger)
                         .generate(location: tavern, characters: [ player, maren ])
    expect(out.internal_state.keys).to eq([ maren.id ])
    expect(captured_prompt).to include("Maren")
    expect(captured_prompt).not_to include("Hero")
  end

  it "calls the LLM and maps NAMES back to character IDs" do
    maren; korr
    llm = StubLLM.new { |_p| good_output([ "Maren", "Korr" ]) }
    out = described_class.new(llm_client: llm, logger: logger)
                         .generate(location: tavern, characters: [ maren, korr ])
    expect(out.internal_state.keys).to contain_exactly(maren.id, korr.id)
    expect(out.internal_state[maren.id]).to match(/Maren is in some/)
    expect(out.internal_state[korr.id]).to match(/Korr is in some/)
  end

  it "extracts extras from the LLM output as an array of descriptions" do
    maren
    llm = StubLLM.new { |_p| good_output([ "Maren" ], extras: [ "an old fisherman nursing a beer at the corner table", "a courier woman finishing a meal" ]) }
    out = described_class.new(llm_client: llm, logger: logger)
                         .generate(location: tavern, characters: [ maren ])
    expect(out.extras).to eq([ "an old fisherman nursing a beer at the corner table", "a courier woman finishing a meal" ])
  end

  it "maps an agenda from character_name to character_id" do
    maren; korr
    llm = StubLLM.new { |_p|
      good_output([ "Maren", "Korr" ], agenda: {
        "character_name" => "Maren",
        "text"           => "wants to ask the player about the docks; her brother went missing last week and the player just walked in"
      })
    }
    out = described_class.new(llm_client: llm, logger: logger)
                         .generate(location: tavern, characters: [ maren, korr ])
    expect(out.agendas).to eq({ maren.id => "wants to ask the player about the docks; her brother went missing last week and the player just walked in" })
  end

  it "agendas default to {} when LLM omits the field" do
    maren
    llm = StubLLM.new { |_p| good_output([ "Maren" ]) }
    out = described_class.new(llm_client: llm, logger: logger)
                         .generate(location: tavern, characters: [ maren ])
    expect(out.agendas).to eq({})
  end

  it "extras default to [] when LLM omits them" do
    maren
    llm = StubLLM.new { |_p| { "internal_states" => { "Maren" => "Maren is quietly in a plausible mood here." } }.to_json }
    out = described_class.new(llm_client: llm, logger: logger)
                         .generate(location: tavern, characters: [ maren ])
    expect(out.extras).to eq([])
  end

  it "extras are silently capped to MAX_EXTRAS=4" do
    maren
    llm = StubLLM.new { |_p| good_output([ "Maren" ], extras: [
      "an old fisherman at the corner table nursing a single beer",
      "a young woman knitting by the warmth of the small fire",
      "two men playing dice in the back, voices low and tense",
      "a courier woman finishing a meal, satchel still slung",
      "a fifth extra that should be silently dropped by the cap"
    ]) }
    out = described_class.new(llm_client: llm, logger: logger)
                         .generate(location: tavern, characters: [ maren ])
    expect(out.extras.size).to eq(4)
  end

  it "retries on validation failure, then accepts" do
    maren
    attempt = 0
    llm = StubLLM.new { |_p|
      attempt += 1
      attempt == 1 ? '{"internal_states": "not-an-object"}' : good_output([ "Maren" ])
    }
    out = described_class.new(llm_client: llm, logger: logger, max_retries: 1)
                         .generate(location: tavern, characters: [ maren ])
    expect(attempt).to eq(2)
    expect(out.internal_state[maren.id]).to be_a(String)
  end

  it "raises after exhausting retries" do
    maren
    llm = StubLLM.new { |_p| '{"internal_states": "not-an-object"}' }
    expect {
      described_class.new(llm_client: llm, logger: logger, max_retries: 0)
                     .generate(location: tavern, characters: [ maren ])
    }.to raise_error(Harness::Scene::InternalState::Hydrator::InvalidOutput)
  end

  describe "cache prefix stability" do
    it_behaves_like "stable cache prefix" do
      let(:maren_local) { Npc.create!(name: "Maren", subrole: "barkeep",  location: tavern) }
      let(:korr_local)    { Npc.create!(name: "Korr",    subrole: "stranger", location: tavern) }

      let(:llm) {
        attempt = 0
        StubLLM.new do |user|
          attempt += 1
          # Trigger the repair path on the first attempt of the FIRST call
          # (single-character input). After that, return a hand-tailored output
          # matching whichever characters appear in the INPUT.
          if attempt == 1
            '{"internal_states": "not-an-object"}'
          else
            states = {}
            states["Maren"] = "Maren seems quietly preoccupied this evening." if user.include?("Maren")
            states["Korr"]    = "Korr keeps glancing toward the door, restless."  if user.include?("Korr")
            { "internal_states" => states }.to_json
          end
        end
      }

      let(:exercise) {
        maren_local; korr_local
        -> {
          described_class.new(llm_client: llm, logger: logger, max_retries: 1)
            .generate(location: tavern, characters: [ maren_local ])
          described_class.new(llm_client: llm, logger: logger)
            .generate(location: tavern, characters: [ maren_local, korr_local ])
        }
      }
    end
  end

  it "passes recent events into the prompt for context" do
    maren
    Event.create!(game_time: 100, scope: "personal", location: tavern, details: { "summary" => "had a rough morning" }).tap do |ev|
      EventParticipant.create!(event: ev, character: maren, role: "actor")
    end

    captured_prompt = nil
    llm = StubLLM.new { |user|
      captured_prompt = user
      good_output([ "Maren" ])
    }
    described_class.new(llm_client: llm, logger: logger)
                   .generate(location: tavern, characters: [ maren ])
    expect(captured_prompt).to include("had a rough morning")
  end
end
