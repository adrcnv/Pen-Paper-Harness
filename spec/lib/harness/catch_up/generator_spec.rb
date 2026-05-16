require "rails_helper"

RSpec.describe Harness::CatchUp::Generator do
  let(:logger)   { Logger.new(IO::NULL) }
  let(:saltmere) { Location.create!(name: "Saltmere", description: "harbor town", x: 10.0, y: 10.0, biome: "lowland") }
  let(:tavern)   { Location.create!(name: "Tavern", description: "smoky common room", parent: saltmere) }

  def stub_call_returning(*responses)
    state = { i: -1 }
    StubLLM.new { |_p|
      state[:i] += 1
      responses[state[:i]]
    }
  end

  def well_formed_payload(game_times)
    {
      "events" => game_times.map { |gt|
        {
          "game_time"    => gt,
          "scope"        => "local",
          "details"      => { "summary" => "a quiet afternoon", "narrative" => "Some traveler passed through." },
          "participants" => [ { "actor_name" => "Korr", "role" => "traveler" } ]
        }
      }
    }.to_json
  end

  describe "skip cases" do
    it "returns [] when llm_client is nil" do
      Event.create!(game_time: 100, scope: "local", location: tavern, details: {})
      out = described_class.new(llm_client: nil, logger: logger).generate(location: tavern, current_game_time: 5000)
      expect(out).to eq([])
    end

    it "returns [] when location has no prior events" do
      llm = StubLLM.new { |_p| raise "should not be called" }
      out = described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)
      expect(out).to eq([])
    end

    it "returns [] when gap is below MIN_GAP" do
      Event.create!(game_time: 4990, scope: "local", location: tavern, details: {})
      llm = StubLLM.new { |_p| raise "should not be called" }
      out = described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)
      expect(out).to eq([])
    end
  end

  describe "happy path" do
    before do
      Event.create!(game_time: 1000, scope: "local", location: tavern, details: { "summary" => "the bar opens" })
      # Post-Phase-2: catch-up may ONLY reference names of existing class-4
      # rows at this location. Korr lives at the tavern so the hydrator
      # accepts him; without this row the well_formed_payload would be rejected.
      Npc.create!(name: "Korr", location: tavern)
    end

    it "commits the cluster at the location with scope=local" do
      llm = stub_call_returning(well_formed_payload([ 2000, 3500 ]))

      expect {
        out = described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)
        expect(out.size).to eq(2)
        expect(out.map(&:location)).to all(eq(tavern))
        expect(out.map(&:scope)).to all(eq("local"))
        expect(out.map(&:game_time)).to eq([ 2000, 3500 ])
      }.to change(Event, :count).by(2)
    end

    it "links participants to the existing class-4 row at this location (no row creation)" do
      llm = stub_call_returning(well_formed_payload([ 2000 ]))

      expect {
        described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)
      }.not_to change { Npc.count }  # catch-up never creates rows; only references existing ones

      korr = Npc.find_by!(name: "Korr", location: tavern)
      parts = EventParticipant.joins(:event).where(events: { location_id: tavern.id, game_time: 2000 })
      expect(parts.pluck(:character_id)).to eq([ korr.id ])
    end

    it "returns [] when generator emits 0 events" do
      llm = stub_call_returning({ "events" => [] }.to_json)
      out = described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)
      expect(out).to eq([])
    end
  end

  describe "retry on malformed output" do
    before do
      Event.create!(game_time: 1000, scope: "local", location: tavern, details: {})
    end

    it "retries once on bad JSON, then commits" do
      Npc.create!(name: "Korr", location: tavern)
      llm = stub_call_returning("not json", well_formed_payload([ 2000 ]))

      expect {
        out = described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)
        expect(out.size).to eq(1)
      }.to change(Event, :count).by(1)
    end

    it "returns [] after exhausting retries" do
      llm = stub_call_returning("not json", "still not json")

      expect {
        out = described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)
        expect(out).to eq([])
      }.not_to change(Event, :count)
    end
  end

  describe "input prompt construction" do
    before do
      Event.create!(game_time: 1000, scope: "local", location: tavern, details: { "summary" => "the bar opens" })
      ev = Event.create!(game_time: 1500, scope: "local", location: tavern, details: { "summary" => "regular night" })
      # post-class-2: recent_actors aggregates over real Character rows at this location.
      korr = Npc.create!(name: "Korr", location_id: tavern.id)
      EventParticipant.create!(event: ev, character: korr, role: "patron")
      EventParticipant.create!(event: ev, character: korr, role: "patron")
    end

    it "includes recent_actors and floor in the prompt" do
      seen = nil
      llm = StubLLM.new { |p|
        seen = p
        { "events" => [] }.to_json
      }

      described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)

      expect(seen).to include("Korr")
      expect(seen).to include("\"floor_game_time\": 1500")
      expect(seen).to include("\"current_game_time\": 5000")
      expect(seen).to include("\"gap\": 3500")
    end

    it "excludes followers (following_player=true) from recent_actors" do
      # An NPC currently following the player is at this location_id (just
      # arrived with the player), but they were NOT solo here during the
      # catch-up window. They must not be surfaced as a reuse candidate;
      # otherwise CatchUp invents bogus solo events naming them.
      ev = Event.create!(game_time: 1500, scope: "local", location: tavern, details: { "summary" => "n" })
      ally = Npc.create!(name: "Ally", location_id: tavern.id,
                         properties: { "following_player" => true })
      EventParticipant.create!(event: ev, character: ally, role: "patron")

      seen = nil
      llm = StubLLM.new { |p|
        seen = p
        { "events" => [] }.to_json
      }

      described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)

      # Korr (non-follower) still appears; Ally (follower) is filtered out.
      expect(seen).to include("Korr")
      expect(seen).not_to include("Ally")
    end
  end

  describe "participants must be class-4 at this location (post-Phase-2)" do
    # Catch-up may only reference existing class-4 names AT this location.
    # Fresh names and names from other locations are rejected by the hydrator.
    before do
      Event.create!(game_time: 1000, scope: "local", location: tavern, details: {})
    end

    def cluster_with(name)
      {
        "events" => [
          { "game_time" => 2000, "scope" => "local",
            "details" => { "summary" => "a quiet hour" },
            "participants" => [ { "actor_name" => name, "role" => "traveler" } ] }
        ]
      }.to_json
    end

    it "rejects a cluster naming a character living elsewhere, then commits the retry naming a local" do
      Npc.create!(name: "Elara Vane", location: saltmere)  # at the parent city, not the tavern
      korr = Npc.create!(name: "Korr", location: tavern)   # the local allowed name

      llm = stub_call_returning(cluster_with("Elara Vane"), cluster_with("Korr"))

      expect {
        out = described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)
        expect(out.size).to eq(1)
      }.not_to change { Npc.count }

      parts = EventParticipant.joins(:event).where(events: { location_id: tavern.id, game_time: 2000 })
      expect(parts.pluck(:character_id)).to eq([ korr.id ])

      retry_user_calls = llm.user_calls.select { |u| u.include?("YOUR PREVIOUS OUTPUT WAS REJECTED") }
      expect(retry_user_calls.first).to include("PARTICIPANTS MUST BE ONE OF THESE")
      expect(retry_user_calls.first).to include("Korr")
    end

    it "links to an existing class-4 row when a name belongs to a character AT this location" do
      korr = Npc.create!(name: "Korr", location: tavern)
      llm = stub_call_returning(cluster_with("Korr"))

      expect {
        described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)
      }.not_to change { Npc.where(name: "Korr").count }

      parts = EventParticipant.joins(:event).where(events: { location_id: tavern.id, game_time: 2000 })
      expect(parts.pluck(:character_id)).to eq([ korr.id ])
    end

    it "rejects dormant historicals at this location as participants (dormant filtered from allowed_names)" do
      # A dormant historical exists at the tavern (genesis-spawned).
      # Catch-up must NOT name them — they're structurally placeholder
      # rows, not active actors during the gap window.
      Npc.create!(name: "Ghost", location: tavern, properties: { "dormant" => true })
      llm = stub_call_returning(cluster_with("Ghost"), { "events" => [] }.to_json)

      expect {
        out = described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)
        expect(out).to eq([])
      }.not_to change(Event, :count)
    end
  end

  describe "hydrator gap window enforcement" do
    before do
      Event.create!(game_time: 1000, scope: "local", location: tavern, details: {})
      Npc.create!(name: "Korr", location: tavern)
    end

    it "drops events at game_time outside the gap window" do
      bad = {
        "events" => [
          { "game_time" => 500,  "scope" => "local", "details" => { "summary" => "before floor" }, "participants" => [ { "actor_name" => "Korr", "role" => "x" } ] }
        ]
      }.to_json
      good = well_formed_payload([ 2000 ])
      llm = stub_call_returning(bad, good)

      expect {
        out = described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)
        expect(out.size).to eq(1)
        expect(out.first.game_time).to eq(2000)
      }.to change(Event, :count).by(1)
    end
  end

  describe "scenario rolling" do
    before do
      Event.create!(game_time: 1000, scope: "local", location: tavern, details: { "summary" => "the bar opens" })
      Npc.create!(name: "Korr", location: tavern)
    end

    def with_scenario(id:, prompt_seed:)
      result = ::Harness::Scenarios::Roller::Result.new(id: id, prompt_seed: prompt_seed)
      allow(::Harness::Scenarios::Roller).to receive(:roll).and_return(result)
      yield
    end

    it "appends the scenario seed to user content when one is rolled" do
      llm = stub_call_returning(well_formed_payload([ 2000 ]))
      with_scenario(id: "minor_theft", prompt_seed: "SCENARIO: minor theft here") do
        described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)
      end
      expect(llm.user_calls.first).to include("SCENARIO: minor theft here")
    end

    it "does NOT append a scenario directive when ambient_color rolled" do
      llm = stub_call_returning(well_formed_payload([ 2000 ]))
      with_scenario(id: "ambient_color", prompt_seed: nil) do
        described_class.new(llm_client: llm, logger: logger).generate(location: tavern, current_game_time: 5000)
      end
      expect(llm.user_calls.first).not_to include("SCENARIO:")
    end

    it "loads the catch_up table without error and uses it by default" do
      llm = stub_call_returning(well_formed_payload([ 2000 ]))
      expect {
        described_class.new(
          llm_client: llm, logger: logger,
          rng: Random.new(0)
        ).generate(location: tavern, current_game_time: 5000)
      }.not_to raise_error
    end

    it "scenario_seed routes to user, never to system (cache prefix preserved across scenarios)" do
      base = ::Harness::CatchUp::Prompt.render(
        location_name: "Tavern", description: "smoky", parent_name: "Saltmere", biome: "lowland",
        current_game_time: 5000, floor_game_time: 1000,
        scenario_seed: nil
      )
      with_seed = ::Harness::CatchUp::Prompt.render(
        location_name: "Tavern", description: "smoky", parent_name: "Saltmere", biome: "lowland",
        current_game_time: 5000, floor_game_time: 1000,
        scenario_seed: "SCENARIO: a thing"
      )
      expect(base[:system]).to eq(with_seed[:system])
      expect(with_seed[:user]).to include("SCENARIO: a thing")
      expect(base[:user]).not_to include("SCENARIO:")
    end
  end

  describe "cache prefix stability" do
    let(:other_loc) { Location.create!(name: "Smithy", description: "ringing forge", parent: saltmere) }

    before do
      Event.create!(game_time: 1000, scope: "local", location: tavern,    details: { "summary" => "the bar opens" })
      Event.create!(game_time: 1500, scope: "local", location: other_loc, details: { "summary" => "first bell" })
    end

    it_behaves_like "stable cache prefix" do
      # Two generate() calls at different locations + a hydrator-rejection
      # retry on the first to also exercise the repair path.
      let(:llm) {
        attempt = 0
        StubLLM.new do |_user|
          attempt += 1
          if attempt == 1
            "definitely not json"  # forces hydrator retry
          else
            { "events" => [] }.to_json
          end
        end
      }

      let(:exercise) {
        -> {
          described_class.new(llm_client: llm, logger: logger, max_retries: 1)
            .generate(location: tavern,    current_game_time: 5000)
          described_class.new(llm_client: llm, logger: logger)
            .generate(location: other_loc, current_game_time: 8000)
        }
      }
    end
  end
end
