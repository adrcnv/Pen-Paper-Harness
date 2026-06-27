require "rails_helper"

RSpec.describe Harness::Genesis::Hydrator do
  def hydrate(obj, current_game_time: 1000)
    described_class.hydrate(
      llm_output:        obj.is_a?(String) ? obj : obj.to_json,
      current_game_time: current_game_time
    )
  end

  it "accepts a well-formed cluster (characters + events)" do
    out = hydrate({
      "characters" => [
        { "id" => "founder", "subrole" => "warlord" }
      ],
      "events" => [
        {
          "game_time"    => 100,
          "scope"        => "local",
          "details"      => { "summary" => "founded" },
          "participants" => [ { "actor_id" => "founder", "role" => "founder" } ]
        }
      ]
    })
    expect(out.characters.size).to eq(1)
    expect(out.characters.first).to include("id" => "founder", "subrole" => "warlord")
    expect(out.events.size).to eq(1)
    expect(out.events.first["participants"].first).to include("actor_id" => "founder", "role" => "founder")
  end

  it "accepts an empty cluster" do
    out = hydrate({ "events" => [] })
    expect(out.events).to eq([])
    expect(out.characters).to eq([])
  end

  describe "characters[] validation" do
    it "rejects malformed id (must be snake_case slug)" do
      expect {
        hydrate({
          "characters" => [ { "id" => "Founder With Spaces", "subrole" => "x" } ],
          "events" => []
        })
      }.to raise_error(described_class::InvalidOutput, /snake_case/)
    end

    it "rejects duplicate ids" do
      expect {
        hydrate({
          "characters" => [
            { "id" => "founder", "subrole" => "warlord" },
            { "id" => "founder", "subrole" => "scribe" }
          ],
          "events" => []
        })
      }.to raise_error(described_class::InvalidOutput, /appears more than once/)
    end

    it "rejects missing subrole" do
      expect {
        hydrate({
          "characters" => [ { "id" => "founder" } ],
          "events" => []
        })
      }.to raise_error(described_class::InvalidOutput, /subrole must be/)
    end
  end

  describe "events[] referential integrity" do
    it "rejects event participants whose actor_id isn't in characters[]" do
      expect {
        hydrate({
          "characters" => [ { "id" => "founder", "subrole" => "warlord" } ],
          "events" => [
            { "game_time" => 100, "scope" => "local", "details" => {},
              "participants" => [ { "actor_id" => "ghost", "role" => "x" } ] }
          ]
        })
      }.to raise_error(described_class::InvalidOutput, /not declared in characters/)
    end

    it "rejects legacy actor_name field with a helpful migration message" do
      expect {
        hydrate({
          "characters" => [ { "id" => "founder", "subrole" => "warlord" } ],
          "events" => [
            { "game_time" => 100, "scope" => "local", "details" => {},
              "participants" => [ { "actor_name" => "Aelin", "role" => "founder" } ] }
          ]
        })
      }.to raise_error(described_class::InvalidOutput, /actor_name.*retired.*actor_id/)
    end
  end

  it "rejects non-JSON" do
    expect { hydrate("not json") }.to raise_error(described_class::InvalidOutput, /not valid JSON/)
  end

  it "rejects when events is missing" do
    expect { hydrate({}) }.to raise_error(described_class::InvalidOutput, /events.*must be an array/)
  end

  it "rejects events past the current game_time" do
    expect {
      hydrate({
        "characters" => [ { "id" => "a", "subrole" => "x" } ],
        "events" => [
          { "game_time" => 1000, "scope" => "local", "details" => {}, "participants" => [ { "actor_id" => "a", "role" => "x" } ] }
        ]
      }, current_game_time: 1000)
    }.to raise_error(described_class::InvalidOutput, /must be strictly less than current_game_time/)
  end

  it "rejects events with bad scope" do
    expect {
      hydrate({
        "characters" => [ { "id" => "a", "subrole" => "x" } ],
        "events" => [
          { "game_time" => 100, "scope" => "kingdom", "details" => {}, "participants" => [ { "actor_id" => "a", "role" => "x" } ] }
        ]
      })
    }.to raise_error(described_class::InvalidOutput, /scope.*must be one of/)
  end

  it "rejects events past MAX_EVENTS" do
    too_many = 9.times.map { |i|
      { "game_time" => 100 + i, "scope" => "local", "details" => {}, "participants" => [ { "actor_id" => "a", "role" => "x" } ] }
    }
    expect {
      hydrate({ "characters" => [ { "id" => "a", "subrole" => "x" } ], "events" => too_many })
    }.to raise_error(described_class::InvalidOutput, /exceeds MAX_EVENTS/)
  end
end
