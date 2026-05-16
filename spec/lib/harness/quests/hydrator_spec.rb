require "rails_helper"

RSpec.describe Harness::Quests::Hydrator do
  let(:archetype) do
    Harness::Quests::Library.find("missing_courier")
  end

  let(:valid_payload) do
    {
      "name"                              => "Recover Helmrest's shipment",
      "summary"                            => "A merchant's grain was waylaid; the player must trace and recover it.",
      "kickoff_narrative"                  => "The merchant told a circle of regulars at the warehouse — the courier never came back.",
      "kickoff_game_time_offset_minutes"   => 4200,
      "kickoff_participant_slots"          => [ "giver", "supporters[0]", "supporters[1]", "antagonist" ],
      "characters" => [
        { "slot" => "giver",       "subrole" => "merchant",       "placement" => "giver_sublocation" },
        { "slot" => "supporters",  "subrole" => "dockhand",       "placement" => "city" },
        { "slot" => "supporters",  "subrole" => "barkeep",        "placement" => "city" },
        { "slot" => "antagonist",  "subrole" => "bandit_leader",  "placement" => "antagonist_sublocation" }
      ],
      "reused_characters" => [],
      "locations" => [
        { "slot" => "giver_sublocation",     "name" => "Holt's Warehouse", "description" => "A wooden warehouse along the docks." },
        { "slot" => "antagonist_sublocation", "name" => "The Salt Quarry",  "description" => "An abandoned quarry above the coast." }
      ],
      "items" => [
        { "slot" => "cargo", "subrole" => "document", "anchored_at" => "antagonist_sublocation" }
      ],
      "steps" => [
        { "description" => "Speak with the dockhand about the caravan's route" },
        { "description" => "Press the barkeep for who paid them off" },
        { "description" => "Track the bandit captain to the Salt Quarry" },
        { "description" => "Recover the cargo" }
      ]
    }
  end

  it "accepts a complete valid payload with all fresh spawns" do
    out = described_class.hydrate(
      llm_output:        valid_payload,
      archetype:         archetype,
      current_game_time: 100_000,
      local_cast:        []
    )
    expect(out[:characters].size).to eq(4)
    expect(out[:reused_characters].size).to eq(0)
    expect(out[:kickoff_participant_slots].size).to eq(4)
    expect(out[:locations].size).to eq(2)
    expect(out[:items].size).to eq(1)
    expect(out[:steps].size).to eq(4)
    # Characters must NOT contain name fields (engine assigns mechanically).
    expect(out[:characters]).to all(not_include("name"))
  end

  it "accepts a payload with mixed fresh + reused characters" do
    payload = valid_payload.deep_dup
    # Drop the second supporter from fresh; reuse local cast id=99 instead.
    payload["characters"].delete_at(2)
    payload["reused_characters"] = [ { "slot" => "supporters", "existing_character_id" => 99 } ]
    out = described_class.hydrate(
      llm_output:        payload,
      archetype:         archetype,
      current_game_time: 100_000,
      local_cast:        [ { "id" => 99, "name" => "Silas Holdwick", "subrole" => "barkeep" } ]
    )
    expect(out[:characters].size).to eq(3)
    expect(out[:reused_characters].size).to eq(1)
    expect(out[:reused_characters].first["existing_character_id"]).to eq(99)
  end

  it "rejects reuse referring to an id not in local_cast" do
    payload = valid_payload.deep_dup
    payload["characters"].delete_at(2)
    payload["reused_characters"] = [ { "slot" => "supporters", "existing_character_id" => 999 } ]
    expect {
      described_class.hydrate(llm_output: payload, archetype: archetype, current_game_time: 100_000, local_cast: [ { "id" => 99, "name" => "X", "subrole" => "y" } ])
    }.to raise_error(described_class::InvalidOutput, /local_cast/)
  end

  it "rejects reuse of the same id more than once" do
    payload = valid_payload.deep_dup
    payload["characters"] = []  # all four slots reused
    payload["reused_characters"] = [
      { "slot" => "giver", "existing_character_id" => 99 },
      { "slot" => "supporters", "existing_character_id" => 99 },
      { "slot" => "supporters", "existing_character_id" => 100 },
      { "slot" => "antagonist", "existing_character_id" => 101 }
    ]
    cast = [
      { "id" => 99,  "name" => "A", "subrole" => "x" },
      { "id" => 100, "name" => "B", "subrole" => "x" },
      { "id" => 101, "name" => "C", "subrole" => "x" }
    ]
    expect {
      described_class.hydrate(llm_output: payload, archetype: archetype, current_game_time: 100_000, local_cast: cast)
    }.to raise_error(described_class::InvalidOutput, /reused more than once/)
  end

  it "rejects characters[] entries with names (engine owns naming)" do
    payload = valid_payload.deep_dup
    # An LLM that ignores instructions and writes a name. Hydrator doesn't
    # actively reject — it just drops the name silently. Verify the name is
    # absent in the output.
    payload["characters"][0]["name"] = "Marcus Holt"
    out = described_class.hydrate(
      llm_output: payload, archetype: archetype, current_game_time: 100_000, local_cast: []
    )
    # Name is not in the output; committer will assign mechanically.
    expect(out[:characters].first.keys).to contain_exactly("slot", "subrole", "placement")
  end

  it "rejects giver placement that isn't giver_sublocation" do
    bad = valid_payload.deep_dup
    bad["characters"].find { |c| c["slot"] == "giver" }["placement"] = "city"
    expect {
      described_class.hydrate(llm_output: bad, archetype: archetype, current_game_time: 100_000, local_cast: [])
    }.to raise_error(described_class::InvalidOutput, /giver/)
  end

  it "rejects wrong step count" do
    bad = valid_payload.deep_dup
    bad["steps"].pop
    expect {
      described_class.hydrate(llm_output: bad, archetype: archetype, current_game_time: 100_000, local_cast: [])
    }.to raise_error(described_class::InvalidOutput, /steps must have/)
  end

  it "rejects missing antagonist_sublocation" do
    bad = valid_payload.deep_dup
    bad["locations"].reject! { |l| l["slot"] == "antagonist_sublocation" }
    expect {
      described_class.hydrate(llm_output: bad, archetype: archetype, current_game_time: 100_000, local_cast: [])
    }.to raise_error(described_class::InvalidOutput, /antagonist_sublocation/)
  end

  it "rejects kickoff offset that pushes the kickoff before time 0" do
    bad = valid_payload.deep_dup
    bad["kickoff_game_time_offset_minutes"] = 200
    expect {
      described_class.hydrate(llm_output: bad, archetype: archetype, current_game_time: 100, local_cast: [])
    }.to raise_error(described_class::InvalidOutput, /kickoff/)
  end

  it "rejects kickoff_participant_slots referencing an out-of-range index" do
    bad = valid_payload.deep_dup
    bad["kickoff_participant_slots"] = [ "giver", "supporters[5]", "antagonist" ]
    expect {
      described_class.hydrate(llm_output: bad, archetype: archetype, current_game_time: 100_000, local_cast: [])
    }.to raise_error(described_class::InvalidOutput, /index 5 out of range/)
  end

  it "rejects kickoff_participant_slots referencing an unknown slot" do
    bad = valid_payload.deep_dup
    bad["kickoff_participant_slots"] = [ "ghost" ]
    expect {
      described_class.hydrate(llm_output: bad, archetype: archetype, current_game_time: 100_000, local_cast: [])
    }.to raise_error(described_class::InvalidOutput, /no fills/)
  end

  it "rejects character slot count mismatch (total = fresh + reused)" do
    bad = valid_payload.deep_dup
    bad["characters"].reject! { |c| c["slot"] == "supporters" }  # 0 supporter fills
    expect {
      described_class.hydrate(llm_output: bad, archetype: archetype, current_game_time: 100_000, local_cast: [])
    }.to raise_error(described_class::InvalidOutput, /supporters/)
  end

  describe "floor constraint on reused characters" do
    # Construct a reuse payload: 3 fresh + 1 reused supporter, all kickoff
    # participants. Vary the kickoff offset to land before/after the reused
    # character's existence floor.
    def reuse_payload(offset:, reused_id: 99)
      p = valid_payload.deep_dup
      sup_idx = p["characters"].index { |c| c["slot"] == "supporters" }
      p["characters"].delete_at(sup_idx)
      p["reused_characters"] = [ { "slot" => "supporters", "existing_character_id" => reused_id } ]
      p["kickoff_game_time_offset_minutes"] = offset
      p["kickoff_participant_slots"] = [ "giver", "supporters[0]", "supporters[1]", "antagonist" ]
      p
    end

    it "accepts reuse when the proposed kickoff is at or after the reused char's floor" do
      cast = [ { "id" => 99, "name" => "X", "subrole" => "y", "earliest_event_game_time" => 90_000 } ]
      # current=100_000, offset=5000 → kickoff=95_000 >= floor=90_000 → ok
      expect {
        described_class.hydrate(llm_output: reuse_payload(offset: 5000), archetype: archetype, current_game_time: 100_000, local_cast: cast)
      }.not_to raise_error
    end

    it "rejects reuse when kickoff is before the reused char's floor" do
      cast = [ { "id" => 99, "name" => "X", "subrole" => "y", "earliest_event_game_time" => 99_500 } ]
      # current=100_000, offset=5000 → kickoff=95_000 < floor=99_500 → violation
      expect {
        described_class.hydrate(llm_output: reuse_payload(offset: 5000), archetype: archetype, current_game_time: 100_000, local_cast: cast)
      }.to raise_error(described_class::InvalidOutput, /earliest_event_game_time/)
    end

    it "tolerates nil floor (dormant Genesis spawn with no events yet)" do
      cast = [ { "id" => 99, "name" => "X", "subrole" => "y", "earliest_event_game_time" => nil } ]
      expect {
        described_class.hydrate(llm_output: reuse_payload(offset: 9000), archetype: archetype, current_game_time: 100_000, local_cast: cast)
      }.not_to raise_error
    end

    it "surfaces a fixable max_safe_offset in the error message" do
      cast = [ { "id" => 99, "name" => "X", "subrole" => "y", "earliest_event_game_time" => 99_500 } ]
      err = nil
      begin
        described_class.hydrate(llm_output: reuse_payload(offset: 5000), archetype: archetype, current_game_time: 100_000, local_cast: cast)
      rescue described_class::InvalidOutput => e
        err = e
      end
      expect(err.errors.first).to include("offset <= 500")
    end
  end

  # Defining `not_include` as inline matcher for the assertion above —
  # alternative: `not include("name")`. Using a one-liner for readability.
  RSpec::Matchers.define :not_include do |key|
    match { |hash| !hash.key?(key) }
  end
end
