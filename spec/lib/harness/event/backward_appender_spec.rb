require "rails_helper"

RSpec.describe Harness::Event::BackwardAppender do
  let(:city)    { Location.create!(name: "Saltmere") }
  let(:tavern)  { Location.create!(name: "Tavern", parent: city) }
  let(:maren) { Npc.create!(name: "Maren", subrole: "barkeep", location: tavern) }
  let(:korr)    { Npc.create!(name: "Korr",    subrole: "stranger", location: tavern) }
  let(:logger)  { Logger.new(IO::NULL) }

  let(:consistent_judgment) {
    StubLLM.new { |_p| { "consistent" => true, "reasons" => [] }.to_json }
  }

  describe "no after_set" do
    it "commits without calling the validator when there are no later events" do
      result = nil
      expect {
        result = described_class.append(
          events: [ {
            game_time:    50,
            scope:        "personal",
            location:     tavern,
            details:      { "narrative" => { "trigger" => "x", "details" => "y" } },
            participants: [ { character: maren, role: "actor" } ]
          } ],
          llm_client: StubLLM.new { |_p| raise "should not be called" },
          logger:     logger
        )
      }.to change(Event, :count).by(1)
      expect(result.events.first.game_time).to eq(50)
      expect(result.events.first.scope).to eq("personal")
      expect(result.after_event_count).to eq(0)
      expect(result.validator_called).to be(false)
    end

    it "is allowed even with no LLM configured (no validator needed)" do
      result = described_class.append(
        events: [ { game_time: 50, scope: "personal", location: tavern, details: {}, participants: [] } ],
        llm_client: nil,
        logger:     logger
      )
      expect(result.events.first).to be_persisted
    end
  end

  describe "with after_set — validator path" do
    before do
      Event.create!(game_time: 100, scope: "personal", location: tavern, details: { "summary" => "the bar opens" })
    end

    it "commits when validator returns consistent: true" do
      expect {
        result = described_class.append(
          events: [ {
            game_time:    50,
            scope:        "personal",
            location:     tavern,
            details:      { "narrative" => { "trigger" => "delivery", "details" => "Maren takes a delivery" } },
            participants: [ { character: maren, role: "actor" } ]
          } ],
          llm_client: consistent_judgment,
          logger:     logger
        )
        expect(result.validator_called).to be(true)
        expect(result.after_event_count).to eq(1)
      }.to change(Event, :count).by(1)
    end

    it "rejects when validator returns consistent: false (no events committed)" do
      llm = StubLLM.new { |_p|
        { "consistent" => false, "reasons" => [ "Maren dies in proposed but lives in later event" ] }.to_json
      }

      expect {
        described_class.append(
          events: [ {
            game_time:    50,
            scope:        "personal",
            location:     tavern,
            details:      { "narrative" => { "trigger" => "death", "details" => "Maren dies" } },
            participants: [ { character: maren, role: "actor" } ]
          } ],
          llm_client: llm,
          logger:     logger
        )
      }.to raise_error(described_class::Rejected) { |e|
        expect(e.reasons.first).to match(/Maren dies/)
      }.and change(Event, :count).by(0)
    end

    it "raises when after_set non-empty but llm_client is nil" do
      expect {
        described_class.append(
          events: [ {
            game_time:    50,
            scope:        "personal",
            location:     tavern,
            details:      {},
            participants: [ { character: maren, role: "actor" } ]
          } ],
          llm_client: nil,
          logger:     logger
        )
      }.to raise_error(described_class::Rejected, /no llm_grunt configured/)
    end
  end

  describe "floor enforcement" do
    before do
      ev = Event.create!(game_time: 80, scope: "personal", location: tavern, details: {})
      EventParticipant.create!(event: ev, character: maren, role: "actor")
    end

    it "raises FloorViolation when proposed game_time is below participant's earliest event" do
      expect {
        described_class.append(
          events: [ {
            game_time:    50,
            scope:        "personal",
            location:     tavern,
            details:      {},
            participants: [ { character: maren, role: "actor" } ]
          } ],
          llm_client: consistent_judgment,
          logger:     logger
        )
      }.to raise_error(described_class::FloorViolation, /below participant Maren/)
    end

    it "allows proposed game_time exactly at the floor" do
      expect {
        described_class.append(
          events: [ {
            game_time:    80,
            scope:        "personal",
            location:     tavern,
            details:      {},
            participants: [ { character: maren, role: "actor" } ]
          } ],
          llm_client: consistent_judgment,
          logger:     logger
        )
      }.to change(Event, :count).by(1)
    end

    it "allows participants without prior events (no floor)" do
      expect {
        described_class.append(
          events: [ {
            game_time:    10,
            scope:        "personal",
            location:     tavern,
            details:      {},
            participants: [ { character: korr, role: "actor" } ]
          } ],
          llm_client: consistent_judgment,
          logger:     logger
        )
      }.to change(Event, :count).by(1)
    end

    it "checks the floor of EVERY participant" do
      expect {
        described_class.append(
          events: [ {
            game_time:    70,
            scope:        "personal",
            location:     tavern,
            details:      {},
            participants: [
              { character: korr,    role: "actor" },
              { character: maren, role: "witness" }
            ]
          } ],
          llm_client: consistent_judgment,
          logger:     logger
        )
      }.to raise_error(described_class::FloorViolation, /Maren/)
    end

    it "EXCLUDES introduction events from floor calculation" do
      # Marta is "introduced" via an audit-only intro event at game_time 100004.
      # That should NOT block backward-append of her actual narrative backstory
      # at an earlier game_time — intro events record "this row was created in-game",
      # not "this character started existing."
      marta = Npc.create!(name: "Marta", subrole: "dock_worker", location: tavern)
      intro = Event.create!(game_time: 100004, scope: "personal", location: tavern,
                            details: { "introduction" => { "target_type" => "character", "target_id" => marta.id, "target_name" => "Marta" } })
      EventParticipant.create!(event: intro, character: marta, role: "subject")

      expect {
        described_class.append(
          events: [ {
            game_time:    50,
            scope:        "local",
            location:     tavern,
            details:      { "narrative" => { "trigger" => "ox-wrestling legend", "details" => "Marta moved cargo no team could" } },
            participants: [ { character: marta, role: "actor" } ]
          } ],
          llm_client: consistent_judgment,
          logger:     logger
        )
      }.to change(Event, :count).by(1)
    end

    it "still enforces the floor against narrative events the character was a participant in" do
      # Marta has both an intro event (excluded) AND a real narrative event.
      # The narrative event sets the floor; the intro event does not.
      marta = Npc.create!(name: "Marta", subrole: "dock_worker", location: tavern)
      intro = Event.create!(game_time: 100004, scope: "personal", location: tavern,
                            details: { "introduction" => { "target_id" => marta.id } })
      EventParticipant.create!(event: intro, character: marta, role: "subject")
      narr = Event.create!(game_time: 1000, scope: "local", location: tavern,
                           details: { "narrative" => { "trigger" => "early deed" } })
      EventParticipant.create!(event: narr, character: marta, role: "actor")

      expect {
        described_class.append(
          events: [ {
            game_time:    500,  # below the narrative floor (1000)
            scope:        "local",
            location:     tavern,
            details:      { "narrative" => { "trigger" => "earlier deed" } },
            participants: [ { character: marta, role: "actor" } ]
          } ],
          llm_client: consistent_judgment,
          logger:     logger
        )
      }.to raise_error(described_class::FloorViolation, /below participant Marta.*game_time=1000/)
    end
  end

  describe "cluster (N>1) shape" do
    it "commits multiple events in chronological order in one transaction" do
      aelin = Npc.create!(name: "Aelin", subrole: "founder", location: tavern)
      cluster = [
        { game_time: 700, scope: "local", location: tavern, details: { "summary" => "founded" },     participants: [ { character: aelin, role: "founder" } ] },
        { game_time: 750, scope: "local", location: tavern, details: { "summary" => "shrine raised" }, participants: [ { character: aelin, role: "patron" } ] }
      ]

      result = nil
      expect {
        result = described_class.append(
          events:     cluster,
          llm_client: consistent_judgment,
          logger:     logger
        )
      }.to change(Event, :count).by(2)
      expect(result.events.map(&:game_time)).to eq([ 700, 750 ])
    end

    it "skips validator entirely for cluster.size==1 with empty after-set" do
      result = described_class.append(
        events: [ { game_time: 700, scope: "local", location: tavern, details: {}, participants: [] } ],
        llm_client: StubLLM.new { |_p| raise "validator should not be called for trivial cluster" },
        logger:     logger
      )
      expect(result.validator_called).to be(false)
      expect(result.events.size).to eq(1)
    end

    it "rolls back the whole cluster if any event fails to commit" do
      bad_cluster = [
        { game_time: 700, scope: "local",   location: tavern, details: {}, participants: [] },
        { game_time: 750, scope: "cosmic",  location: tavern, details: {}, participants: [] }  # invalid scope
      ]

      expect {
        described_class.append(events: bad_cluster, llm_client: nil, logger: logger) rescue nil
      }.not_to change(Event, :count)
    end

    it "validates the cluster as a unit when after_set is non-empty" do
      Event.create!(game_time: 1000, scope: "regional", location: tavern, details: {})
      aelin = Npc.create!(name: "Aelin", subrole: "founder", location: tavern)

      cluster = [
        { game_time: 700, scope: "local", location: tavern, details: {}, participants: [ { character: aelin, role: "founder" } ] },
        { game_time: 750, scope: "local", location: tavern, details: {}, participants: [ { character: aelin, role: "patron" } ] }
      ]

      validator_calls = 0
      llm = StubLLM.new { |_p|
        validator_calls += 1
        { "consistent" => true, "reasons" => [] }.to_json
      }

      result = described_class.append(events: cluster, llm_client: llm, logger: logger)
      expect(validator_calls).to eq(1)  # one validator call per cluster, not per event
      expect(result.events.size).to eq(2)
    end

    it "rejects the whole cluster when validator says inconsistent" do
      Event.create!(game_time: 1000, scope: "regional", location: tavern, details: {})
      aelin = Npc.create!(name: "Aelin", subrole: "founder", location: tavern)
      cluster = [
        { game_time: 700, scope: "local", location: tavern, details: {}, participants: [ { character: aelin, role: "founder" } ] },
        { game_time: 750, scope: "local", location: tavern, details: {}, participants: [ { character: aelin, role: "patron" } ] }
      ]
      llm = StubLLM.new { |_p| { "consistent" => false, "reasons" => [ "Aelin acted after dying" ] }.to_json }

      expect {
        described_class.append(events: cluster, llm_client: llm, logger: logger)
      }.to raise_error(described_class::Rejected, /Aelin acted after dying/).and change(Event, :count).by(0)
    end
  end

  describe "input validation" do
    it "rejects empty events array" do
      expect {
        described_class.append(events: [], llm_client: nil, logger: logger)
      }.to raise_error(ArgumentError, /events must be a non-empty array/)
    end
  end

  describe "hydrator retry" do
    before do
      Event.create!(game_time: 100, scope: "personal", location: tavern, details: {})
    end

    it "retries up to max_retries on malformed validator output, then accepts" do
      attempt = 0
      llm = StubLLM.new { |_p|
        attempt += 1
        attempt == 1 ? "not json at all" : { "consistent" => true, "reasons" => [] }.to_json
      }

      result = described_class.append(
        events: [ {
          game_time:    50,
          scope:        "personal",
          location:     tavern,
          details:      {},
          participants: [ { character: maren, role: "actor" } ]
        } ],
        llm_client:  llm,
        logger:      logger,
        max_retries: 1
      )
      expect(attempt).to eq(2)
      expect(result.validator_called).to be(true)
    end

    it "raises after exhausting retries on malformed output" do
      llm = StubLLM.new { |_p| "still not json" }

      expect {
        described_class.append(
          events: [ {
            game_time:    50,
            scope:        "personal",
            location:     tavern,
            details:      {},
            participants: [ { character: maren, role: "actor" } ]
          } ],
          llm_client:  llm,
          logger:      logger,
          max_retries: 1
        )
      }.to raise_error(::Harness::Event::BackwardAppender::Hydrator::InvalidOutput)
    end
  end

  describe "cache prefix stability" do
    before do
      # Seed an after-event so the validator fires on each append.
      Event.create!(game_time: 100, scope: "personal", location: tavern, details: { "summary" => "later happening" })
    end

    it_behaves_like "stable cache prefix" do
      let(:llm) {
        attempt = 0
        StubLLM.new do |_user|
          attempt += 1
          # First call returns malformed JSON to trigger the validator's
          # repair retry; subsequent calls accept.
          if attempt == 1
            "not json"
          else
            { "consistent" => true, "reasons" => [] }.to_json
          end
        end
      }

      let(:exercise) {
        -> {
          described_class.append(
            events: [ {
              game_time:    50,
              scope:        "personal",
              location:     tavern,
              details:      { "narrative" => { "trigger" => "first" } },
              participants: [ { character: maren, role: "actor" } ]
            } ],
            llm_client: llm,
            logger:     logger,
            max_retries: 1
          )
          described_class.append(
            events: [ {
              game_time:    60,
              scope:        "personal",
              location:     tavern,
              details:      { "narrative" => { "trigger" => "completely different shape with longer prose" } },
              participants: [ { character: korr, role: "witness" } ]
            } ],
            llm_client: llm,
            logger:     logger
          )
        }
      }
    end
  end
end
