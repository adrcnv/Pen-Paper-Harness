require "rails_helper"

RSpec.describe Harness::Genesis::Generator do
  let(:logger)   { Logger.new(IO::NULL) }
  let(:saltmere) { Location.create!(name: "Saltmere", description: "harbor town", x: 10.0, y: 10.0, biome: "lowland") }
  let(:hollowmere) { Location.create!(name: "Hollowmere", description: "a misty hollow village", x: 35.0, y: 12.0, biome: "lowland") }

  # Stats materialization fires per character via Character::Hatchery now,
  # producing extra LLM calls interleaved with the genesis flow. Sequence-based
  # stubbing was fragile; route by prompt-content marker instead. Stats calls
  # always return a baseline-ordinary response so the cluster commits without
  # those extra responses needing to be queued in tests focused on cluster /
  # validator behavior.
  STATS_DEFAULT_RESPONSE = {
    "level" => 1,
    "strength" => 10, "dexterity" => 10, "constitution" => 10,
    "intelligence" => 10, "wisdom" => 10, "charisma" => 10
  }.to_json.freeze

  DESCRIPTION_DEFAULT_RESPONSE = {
    "personality" => "Quiet, watchful; speaks only when spoken to and answers in fewer words than expected.",
    "appearance"  => "Average height, plain dress, hands clean but not soft — the build of someone who has worked but not heavily."
  }.to_json.freeze

  def stub_call_returning(*sequenced_responses)
    state = { i: -1 }
    StubLLM.new { |prompt|
      if prompt.include?("generating a LEVEL and six ability scores")
        STATS_DEFAULT_RESPONSE
      elsif prompt.include?("generating a personality and a physical appearance")
        DESCRIPTION_DEFAULT_RESPONSE
      else
        state[:i] += 1
        sequenced_responses[state[:i]]
      end
    }
  end

  # Post-Phase-3: cluster declares characters[] with mechanical-id slugs;
  # participants reference by actor_id, names are assigned by the engine.
  def well_formed_cluster_json(game_time_floor: 100)
    {
      "characters" => [
        { "id" => "founder", "subrole" => "warlord" }
      ],
      "events" => [
        { "game_time" => game_time_floor,      "scope" => "local", "details" => { "summary" => "founded" },     "participants" => [ { "actor_id" => "founder", "role" => "founder" } ] },
        { "game_time" => game_time_floor + 50, "scope" => "local", "details" => { "summary" => "shrine raised" }, "participants" => [ { "actor_id" => "founder", "role" => "patron" } ] }
      ]
    }.to_json
  end

  let(:consistent_validator_json) {
    { "consistent" => true, "reasons" => [] }.to_json
  }

  let(:rejecting_validator_json) {
    { "consistent" => false, "reasons" => [ "founder acted after dying" ] }.to_json
  }

  it "returns [] when llm_client is nil" do
    out = described_class.new(llm_client: nil, logger: logger).generate(location: hollowmere, anchor: saltmere, current_game_time: 1000)
    expect(out).to eq([])
  end

  it "commits the cluster when generator + validator both pass" do
    llm = stub_call_returning(well_formed_cluster_json, consistent_validator_json)

    expect {
      out = described_class.new(llm_client: llm, logger: logger).generate(location: hollowmere, anchor: saltmere, current_game_time: 1000)
      expect(out.size).to eq(2)
      expect(out.map(&:location)).to all(eq(hollowmere))
      expect(out.map(&:scope)).to all(eq("local"))
    }.to change(Event, :count).by(2)
  end

  it "eager-spawns one dormant class-4 row per characters[] entry, with a mechanical name" do
    llm = stub_call_returning(well_formed_cluster_json, consistent_validator_json)

    expect {
      described_class.new(llm_client: llm, logger: logger).generate(location: hollowmere, anchor: saltmere, current_game_time: 1000)
    }.to change { Npc.count }.by(1)

    fresh = Npc.last
    expect(fresh.location).to eq(hollowmere)
    expect(fresh.properties).to include("dormant" => true)
    # Name came from Naming, not from the LLM — so it's a non-empty string
    # not "Aelin" and not anything in the LLM output.
    expect(fresh.name).to be_a(String)
    expect(fresh.name).not_to be_empty

    parts = EventParticipant.where(event: Event.where(location: hollowmere))
    expect(parts.pluck(:character_id)).to all(eq(fresh.id))
  end

  it "rolls back materialized characters when BackwardAppender rejects the cluster" do
    llm = stub_call_returning(
      well_formed_cluster_json, rejecting_validator_json,
      well_formed_cluster_json, rejecting_validator_json
    )

    expect {
      described_class.new(llm_client: llm, logger: logger).generate(location: hollowmere, anchor: saltmere, current_game_time: 1000)
    }.not_to change { Npc.count }  # no orphan characters from rejected attempts
  end

  it "retries the generator with rejection reasons and commits the second proposal" do
    bad_cluster  = well_formed_cluster_json(game_time_floor: 100)
    good_cluster = well_formed_cluster_json(game_time_floor: 200)
    llm = stub_call_returning(
      bad_cluster, rejecting_validator_json,
      good_cluster, consistent_validator_json
    )

    expect {
      out = described_class.new(llm_client: llm, logger: logger).generate(location: hollowmere, anchor: saltmere, current_game_time: 1000)
      expect(out.size).to eq(2)
    }.to change(Event, :count).by(2)
  end

  it "returns [] (committing nothing) after exhausting rejection retries" do
    llm = stub_call_returning(
      well_formed_cluster_json, rejecting_validator_json,
      well_formed_cluster_json, rejecting_validator_json
    )

    expect {
      out = described_class.new(llm_client: llm, logger: logger).generate(location: hollowmere, anchor: saltmere, current_game_time: 1000)
      expect(out).to eq([])
    }.not_to change(Event, :count)
  end

  it "returns [] when generator emits 0 events (graceful empty cluster)" do
    llm = stub_call_returning({ "events" => [] }.to_json)

    out = described_class.new(llm_client: llm, logger: logger).generate(location: hollowmere, anchor: saltmere, current_game_time: 1000)
    expect(out).to eq([])
  end

  describe "pending_appearances commit" do
    # Two-event cluster so BackwardAppender's validator runs (single-event
    # clusters with empty after-set skip validation, which would let a
    # "rejecting validator" stub never fire).
    def cluster_with_pa(intent: "is desperate for news of his missing son and will probe any traveler from the wilderness")
      {
        "characters" => [
          { "id" => "captain", "subrole" => "captain" }
        ],
        "events" => [
          {
            "game_time"    => 100,
            "scope"        => "local",
            "details"      => { "summary" => "founded" },
            "participants" => [ { "actor_id" => "captain", "role" => "founder" } ]
          },
          {
            "game_time"    => 200,
            "scope"        => "local",
            "details"      => { "summary" => "lost son" },
            "participants" => [ { "actor_id" => "captain", "role" => "father" } ]
          }
        ],
        "pending_appearances" => [
          { "actor_id" => "captain", "intent_text" => intent }
        ]
      }.to_json
    end

    it "commits a pending_appearance when one is in the cluster and a Player exists" do
      Player.create!(name: "Hero", location: saltmere)
      llm = stub_call_returning(cluster_with_pa, consistent_validator_json)

      expect {
        described_class.new(llm_client: llm, logger: logger).generate(location: hollowmere, anchor: saltmere, current_game_time: 1000)
      }.to change { PendingAppearance.count }.by(1)

      pa = PendingAppearance.last
      fresh_captain = Npc.find_by!(location_id: hollowmere.id)
      expect(pa.target_character_id).to eq(Player.first.id)
      expect(pa.actor_character_id).to eq(fresh_captain.id)
      expect(pa.anchor_location_id).to eq(hollowmere.id)
      expect(pa.scope).to eq("city")
      expect(pa.earliest_at).to eq(1000)
      expect(pa.intent_text).to start_with("is desperate")
      expect(pa.triggered_by_event_id).to eq(Event.where(location: hollowmere).first.id)
    end

    it "silently skips pending_appearances when no Player exists yet" do
      llm = stub_call_returning(cluster_with_pa, consistent_validator_json)

      expect {
        described_class.new(llm_client: llm, logger: logger).generate(location: hollowmere, anchor: saltmere, current_game_time: 1000)
      }.not_to change { PendingAppearance.count }
    end

    it "rolls back pending_appearances when BackwardAppender rejects the cluster" do
      Player.create!(name: "Hero", location: saltmere)
      llm = stub_call_returning(
        cluster_with_pa, rejecting_validator_json,
        cluster_with_pa, rejecting_validator_json
      )

      expect {
        described_class.new(llm_client: llm, logger: logger).generate(location: hollowmere, anchor: saltmere, current_game_time: 1000)
      }.not_to change { PendingAppearance.count }
    end
  end

  describe "scenario rolling" do
    def with_scenario(id:, prompt_seed:)
      result = ::Harness::Scenarios::Roller::Result.new(id: id, prompt_seed: prompt_seed)
      allow(::Harness::Scenarios::Roller).to receive(:roll).and_return(result)
      yield
    end

    it "appends the scenario seed to user content when one is rolled" do
      llm = stub_call_returning(well_formed_cluster_json, consistent_validator_json)
      with_scenario(id: "founding_betrayal", prompt_seed: "SCENARIO: betrayal here") do
        described_class.new(llm_client: llm, logger: logger).generate(location: hollowmere, anchor: saltmere, current_game_time: 1000)
      end
      first_user = llm.user_calls.first
      expect(first_user).to include("SCENARIO: betrayal here")
    end

    it "does NOT append a scenario directive when nothing_interesting rolled" do
      llm = stub_call_returning(well_formed_cluster_json, consistent_validator_json)
      with_scenario(id: "nothing_interesting", prompt_seed: nil) do
        described_class.new(llm_client: llm, logger: logger).generate(location: hollowmere, anchor: saltmere, current_game_time: 1000)
      end
      first_user = llm.user_calls.first
      expect(first_user).not_to include("SCENARIO:")
    end

    it "loads the genesis table without error and uses it by default" do
      llm = stub_call_returning(well_formed_cluster_json, consistent_validator_json)
      expect {
        described_class.new(
          llm_client: llm, logger: logger,
          rng: Random.new(0)
        ).generate(location: hollowmere, anchor: saltmere, current_game_time: 1000)
      }.not_to raise_error
    end
  end

  describe "cache prefix stability" do
    let(:other_loc) { Location.create!(name: "Frostgate", description: "ice trader town", x: 50.0, y: 60.0, biome: "highland") }

    it "Genesis::Prompt.render produces byte-stable system across varied inputs" do
      a = ::Harness::Genesis::Prompt.render(
        location_name: "Hollowmere", description: "village",  biome: "lowland",
        anchor_name:   "Saltmere",   anchor_biome: "lowland",
        current_game_time: 1000,
        connection: "x", regional_context: []
      )
      b = ::Harness::Genesis::Prompt.render(
        location_name: "Frostgate",  description: "ice town", biome: "highland",
        anchor_name:   "Saltkeep",   anchor_biome: "lowland",
        current_game_time: 50000,
        connection: "y", regional_context: [ { "id" => 1, "summary" => "war" } ],
        scenario_seed:    "SCENARIO: a different scenario seed",
        rejection_feedback: [ "anachronism", "implausible" ]
      )
      expect(a[:system]).to eq(b[:system])
      expect(a[:system]).not_to be_empty
      expect(a[:user]).not_to eq(b[:user])
    end

    it "scenario_seed routes to user, never to system (preserves cache prefix across scenarios)" do
      base = ::Harness::Genesis::Prompt.render(
        location_name: "Hollowmere", description: "village", biome: "lowland",
        anchor_name: "Saltmere", anchor_biome: "lowland",
        current_game_time: 1000,
        scenario_seed: nil
      )
      with_seed = ::Harness::Genesis::Prompt.render(
        location_name: "Hollowmere", description: "village", biome: "lowland",
        anchor_name: "Saltmere", anchor_biome: "lowland",
        current_game_time: 1000,
        scenario_seed: "SCENARIO: founding betrayal"
      )
      expect(base[:system]).to eq(with_seed[:system])
      expect(with_seed[:user]).to include("SCENARIO: founding betrayal")
      expect(base[:user]).not_to include("SCENARIO:")
    end
  end
end
