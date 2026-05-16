require "rails_helper"

RSpec.describe Harness::Scene::CharacterCatchUp::Generator do
  let(:logger)   { Logger.new(IO::NULL) }
  let(:city)     { Location.create!(name: "Saltmere") }
  let(:tavern)   { Location.create!(name: "Tavern", parent: city) }
  let(:joey)     { Npc.create!(name: "Joey",    subrole: "patron",  location: tavern, properties: { "personality" => "wary" }) }
  let(:smith)    { Npc.create!(name: "Brann",   subrole: "smith",   location: tavern) }
  let(:player)   { Player.create!(name: "Hero", location: tavern) }

  # Most tests need the catch-up filter to allow the character through —
  # characters with zero prior event participation get filtered out as having
  # nothing to catch up about. Seed one historical event per fixture.
  def seed_prior_event!(character, game_time: 100, summary: "did a thing")
    ev = Event.create!(game_time: game_time, scope: "personal", details: { "summary" => summary })
    EventParticipant.create!(event: ev, character: character, role: "actor")
  end

  def well_formed_payload(*char_event_pairs, current_game_time: 5000, lookback: 4320)
    floor = current_game_time - lookback
    {
      "characters" => char_event_pairs.map { |cid, n_events|
        {
          "character_id" => cid,
          "events"       => n_events.times.map { |i|
            {
              "game_time" => floor + 1 + i * 100,
              "summary"   => "did a thing #{i}",
              "narrative" => "details of thing #{i}",
              "role"      => "actor"
            }
          }
        }
      }
    }.to_json
  end

  describe "skip cases" do
    it "returns [] when llm_client is nil" do
      out = described_class.new(llm_client: nil, logger: logger).generate(characters: [ joey ], current_game_time: 5000)
      expect(out).to eq([])
    end

    it "returns [] when characters array is empty" do
      llm = StubLLM.new { |_p| raise "should not be called" }
      out = described_class.new(llm_client: llm, logger: logger).generate(characters: [], current_game_time: 5000)
      expect(out).to eq([])
    end

    it "filters out Player rows (never simulates the player)" do
      llm = StubLLM.new { |_p| raise "should not be called" }
      out = described_class.new(llm_client: llm, logger: logger).generate(characters: [ player ], current_game_time: 5000)
      expect(out).to eq([])
    end
  end

  describe "happy path" do
    before { seed_prior_event!(joey); seed_prior_event!(smith) }

    it "commits personal-scope events with location=null and the character as participant" do
      llm = StubLLM.new { |_p| well_formed_payload([ joey.id, 1 ]) }
      out = nil
      expect {
        out = described_class.new(llm_client: llm, logger: logger).generate(characters: [ joey ], current_game_time: 5000)
      }.to change(Event, :count).by(1)

      expect(out.size).to eq(1)
      ev = out.first
      expect(ev.scope).to eq("personal")
      expect(ev.location).to be_nil
      expect(ev.event_participants.first.character).to eq(joey)
      expect(ev.event_participants.first.role).to eq("actor")
    end

    it "batches multiple characters in one call" do
      # joey:1, smith:2 → smith capped to MAX_EVENTS_PER_CHARACTER (1) → total 2
      llm = StubLLM.new { |_p| well_formed_payload([ joey.id, 1 ], [ smith.id, 2 ]) }
      out = described_class.new(llm_client: llm, logger: logger).generate(characters: [ joey, smith ], current_game_time: 5000)
      expect(out.size).to eq(2)
      expect(llm.user_calls.size).to eq(1)
    end

    it "accepts 0 events for a character (most characters have nothing to report)" do
      llm = StubLLM.new { |_p| { "characters" => [ { "character_id" => joey.id, "events" => [] } ] }.to_json }
      expect {
        described_class.new(llm_client: llm, logger: logger).generate(characters: [ joey ], current_game_time: 5000)
      }.not_to change(Event, :count)
    end

    it "caps events per character at MAX_EVENTS_PER_CHARACTER (1)" do
      llm = StubLLM.new { |_p| well_formed_payload([ joey.id, 5 ]) }
      out = described_class.new(llm_client: llm, logger: logger).generate(characters: [ joey ], current_game_time: 5000)
      expect(out.size).to eq(1)
    end
  end

  describe "history filter" do
    it "skips characters with zero prior event participation (no off-screen to fill in)" do
      called = false
      llm = StubLLM.new { |_p| called = true; well_formed_payload([ joey.id, 1 ]) }
      out = described_class.new(llm_client: llm, logger: logger).generate(characters: [ joey ], current_game_time: 5000)
      expect(out).to eq([])
      expect(called).to be(false)
    end

    it "includes only characters with prior events when mixed in" do
      seed_prior_event!(smith)
      # joey has no events; smith has one
      called_with = nil
      llm = StubLLM.new { |p| called_with = p; well_formed_payload([ smith.id, 1 ]) }
      described_class.new(llm_client: llm, logger: logger).generate(characters: [ joey, smith ], current_game_time: 5000)
      expect(called_with).to include("Brann")
      expect(called_with).not_to include("\"name\": \"Joey\"")
    end
  end

  describe "window enforcement" do
    before { seed_prior_event!(joey) }

    it "drops events with game_time outside the lookback window" do
      bad_payload = {
        "characters" => [
          {
            "character_id" => joey.id,
            "events"       => [
              { "game_time" => 100,  "summary" => "way before", "narrative" => "", "role" => "actor" },     # too early
              { "game_time" => 4900, "summary" => "in window",  "narrative" => "", "role" => "actor" },     # OK
              { "game_time" => 9999, "summary" => "future",     "narrative" => "", "role" => "actor" }      # too late
            ]
          }
        ]
      }.to_json
      llm = StubLLM.new { |_p| bad_payload }
      out = described_class.new(llm_client: llm, logger: logger).generate(characters: [ joey ], current_game_time: 5000)
      expect(out.size).to eq(1)
      expect(out.first.game_time).to eq(4900)
    end

    it "respects custom lookback_window override" do
      llm = StubLLM.new { |_p|
        { "characters" => [ {
          "character_id" => joey.id,
          "events" => [ { "game_time" => 4500, "summary" => "x", "narrative" => "", "role" => "actor" } ]
        } ] }.to_json
      }
      # window=100 means floor=4900; 4500 is below floor → dropped
      out = described_class.new(llm_client: llm, logger: logger, lookback_window: 100).generate(characters: [ joey ], current_game_time: 5000)
      expect(out).to eq([])
    end

    it "filters out character_ids not in the input scope (silent drop)" do
      llm = StubLLM.new { |_p| well_formed_payload([ 99_999, 1 ]) }
      out = described_class.new(llm_client: llm, logger: logger).generate(characters: [ joey ], current_game_time: 5000)
      expect(out).to eq([])
    end
  end

  describe "retry on malformed output" do
    before { seed_prior_event!(joey) }

    it "retries once on bad JSON, then commits" do
      attempt = 0
      llm = StubLLM.new { |_p|
        attempt += 1
        attempt == 1 ? "not json" : well_formed_payload([ joey.id, 1 ])
      }
      expect {
        described_class.new(llm_client: llm, logger: logger).generate(characters: [ joey ], current_game_time: 5000)
      }.to change(Event, :count).by(1)
      expect(attempt).to eq(2)
    end

    it "returns [] after exhausting retries" do
      llm = StubLLM.new { |_p| "still not json" }
      expect {
        described_class.new(llm_client: llm, logger: logger).generate(characters: [ joey ], current_game_time: 5000)
      }.not_to change(Event, :count)
    end
  end

  describe "input prompt construction" do
    it "includes character recent_events from event_participants" do
      ev = Event.create!(game_time: 4000, scope: "local", location: tavern, details: { "summary" => "joey did x" })
      EventParticipant.create!(event: ev, character: joey, role: "actor")
      seen = nil
      llm = StubLLM.new { |p|
        seen = p
        well_formed_payload([ joey.id, 0 ])
      }
      described_class.new(llm_client: llm, logger: logger).generate(characters: [ joey ], current_game_time: 5000)
      expect(seen).to include("joey did x")
      expect(seen).to include("\"current_game_time\": 5000")
      expect(seen).to include("\"lookback_window\": 4320")
    end

    it "includes personality_summary from character.properties" do
      seed_prior_event!(joey)
      seen = nil
      llm = StubLLM.new { |p|
        seen = p
        well_formed_payload([ joey.id, 0 ])
      }
      described_class.new(llm_client: llm, logger: logger).generate(characters: [ joey ], current_game_time: 5000)
      expect(seen).to include("wary")
    end
  end

  describe "cache prefix stability" do
    let(:other) { Npc.create!(name: "Pell", subrole: "scribe", location: tavern, properties: { "personality" => "tidy" }) }

    before { seed_prior_event!(joey); seed_prior_event!(other) }

    it_behaves_like "stable cache prefix" do
      let(:llm) {
        attempt = 0
        StubLLM.new do |_p|
          attempt += 1
          if attempt == 1
            "not json"  # forces hydrator retry
          else
            { "characters" => [] }.to_json
          end
        end
      }

      let(:exercise) {
        c1 = joey
        c2 = other
        -> {
          described_class.new(llm_client: llm, logger: logger, max_retries: 1)
            .generate(characters: [ c1 ], current_game_time: 5000)
          described_class.new(llm_client: llm, logger: logger)
            .generate(characters: [ c2 ], current_game_time: 8000)
        }
      }
    end
  end
end
