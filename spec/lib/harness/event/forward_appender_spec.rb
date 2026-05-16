require "rails_helper"

RSpec.describe Harness::Event::ForwardAppender do
  let(:city) { Location.create!(name: "Saltmere", description: "harbor town") }
  let(:maren) { Npc.create!(name: "Maren", subrole: "barkeep", location: city) }

  describe ".append" do
    it "creates an event with scope, game_time, location, and stringified details" do
      event = described_class.append(
        game_time: 100,
        location:  city,
        scope:     "local",
        details:   { summary: "Fire at the docks", severity: :minor }
      )

      expect(event).to be_persisted
      expect(event.scope).to eq("local")
      expect(event.game_time).to eq(100)
      expect(event.location).to eq(city)
      expect(event.details["summary"]).to eq("Fire at the docks")
      expect(event.details["severity"]).to eq("minor")
    end

    it "allows nil location for world-scope events" do
      event = described_class.append(
        game_time: 1000, location: nil, scope: "world",
        details: { summary: "The sun dimmed" }
      )
      expect(event.location).to be_nil
      expect(event.scope).to eq("world")
    end

    it "stores location_name in details when given a name that doesn't match a row" do
      expect {
        described_class.append(
          game_time: 50, location: "Plains of Korr", scope: "regional"
        )
      }.not_to change(::Location, :count)
      event = ::Event.last
      expect(event.location).to be_nil
      expect(event.details["location_name"]).to eq("Plains of Korr")
    end

    it "reuses an existing Location when given a matching name" do
      existing = Location.create!(name: "Old Town")
      event = described_class.append(
        game_time: 50, location: "Old Town", scope: "local"
      )
      expect(event.location).to eq(existing)
      expect(Location.where(name: "Old Town").count).to eq(1)
    end

    it "accepts class-4 character participants" do
      event = described_class.append(
        game_time: 100, location: city, scope: "local",
        participants: [ { character: maren, role: "victim" } ]
      )
      part = event.event_participants.first
      expect(part.character).to eq(maren)
      expect(part.role).to eq("victim")
    end

    it "rejects an invalid scope" do
      expect {
        described_class.append(game_time: 100, location: city, scope: "cosmic")
      }.to raise_error(described_class::InvalidEvent, /scope/)
    end

    it "rejects a non-integer game_time" do
      expect {
        described_class.append(game_time: "early", location: city, scope: "local")
      }.to raise_error(described_class::InvalidEvent, /game_time/)
    end

    it "rejects a participant with no :character (post-Phase-2: actor_name retired)" do
      expect {
        described_class.append(
          game_time: 100, location: city, scope: "local",
          participants: [ { role: "bystander" } ]
        )
      }.to raise_error(described_class::InvalidEvent, /must have a :character/)
    end

    it "rejects a participant missing role" do
      expect {
        described_class.append(
          game_time: 100, location: city, scope: "local",
          participants: [ { character: maren } ]
        )
      }.to raise_error(described_class::InvalidEvent, /role/)
    end

    it "rolls back the event if a participant fails to save" do
      allow(::EventParticipant).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(::EventParticipant.new))
      expect {
        described_class.append(
          game_time: 100, location: city, scope: "local",
          participants: [ { character: maren, role: "victim" } ]
        )
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect(::Event.count).to eq(0)
    end
  end

  describe "querying after appends (supports NPC-speech filter)" do
    it "returns this character's events via the participants index" do
      korr = Npc.create!(name: "Korr", subrole: "raider", location: city)
      e1 = described_class.append(
        game_time: 1, location: city, scope: "local",
        participants: [ { character: maren, role: "witness" } ]
      )
      e2 = described_class.append(
        game_time: 2, location: city, scope: "local",
        participants: [ { character: maren, role: "victim" } ]
      )
      _unrelated = described_class.append(
        game_time: 3, location: city, scope: "local",
        participants: [ { character: korr, role: "aggressor" } ]
      )

      ids = maren.events.order(:game_time).pluck(:id)
      expect(ids).to eq([ e1.id, e2.id ])
    end

    it "returns events at a location via the location_id index" do
      other = Location.create!(name: "Graveyard")
      described_class.append(game_time: 1, location: city,  scope: "local")
      described_class.append(game_time: 2, location: other, scope: "local")

      expect(::Event.where(location: city).count).to eq(1)
      expect(::Event.where(location: other).count).to eq(1)
    end

    it "filters regional+ via scope index" do
      described_class.append(game_time: 1, location: city, scope: "personal")
      described_class.append(game_time: 2, location: city, scope: "local")
      described_class.append(game_time: 3, location: city, scope: "regional")
      described_class.append(game_time: 4, location: city, scope: "kingdom")
      described_class.append(game_time: 5, location: city, scope: "world")

      expect(::Event.regional_plus.count).to eq(3)
    end

    it "filters events by game_time for cache-invalidation high-water mark" do
      e1 = described_class.append(game_time: 10, location: city, scope: "local",
                                  participants: [ { character: maren, role: "x" } ])
      e2 = described_class.append(game_time: 20, location: city, scope: "local",
                                  participants: [ { character: maren, role: "x" } ])

      fresh_ids = ::Event.joins(:event_participants)
                         .where(event_participants: { character_id: maren.id })
                         .where("events.id > ?", e1.id)
                         .pluck(:id)
      expect(fresh_ids).to eq([ e2.id ])
    end
  end
end
