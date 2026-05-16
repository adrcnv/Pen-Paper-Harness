require "rails_helper"

RSpec.describe Harness::Scene::WitnessTagger do
  let(:logger)  { Logger.new(IO::NULL) }
  let(:city)    { Location.create!(name: "Saltmere") }
  let(:tavern)  { Location.create!(name: "Tavern", parent: city) }
  let(:maren) { Npc.create!(name: "Maren", subrole: "barkeep", location: tavern) }
  let(:korr)    { Npc.create!(name: "Korr",    subrole: "patron",  location: tavern) }
  let(:player)  { Player.create!(name: "Hero", location: tavern) }

  def active(present:, entered_at: 1000)
    # Force-load Assembler so Snapshot constant is defined.
    Harness::Scene::Assembler
    Harness::Scene::Active.new(
      location: tavern,
      snapshot: Harness::Scene::Snapshot.new(
        location:           tavern,
        present_characters: present,
        present_items:      []
      ),
      narrations:           [],
      internal_state:       {},
      entered_at_game_time: entered_at
    )
  end

  describe ".tag" do
    it "tags every present character as witness on events at this location during the scene window" do
      ev = Event.create!(game_time: 1010, scope: "personal", location: tavern, details: { "summary" => "x" })

      added = described_class.tag(active(present: [ maren, korr, player ]), 1020, logger: logger)
      expect(added).to eq(3)
      expect(ev.event_participants.pluck(:character_id, :role)).to contain_exactly(
        [ maren.id, "witness" ],
        [ korr.id,    "witness" ],
        [ player.id,  "witness" ]
      )
    end

    it "skips characters already participating in the event (no double-tag)" do
      ev = Event.create!(game_time: 1010, scope: "personal", location: tavern, details: {})
      EventParticipant.create!(event: ev, character: maren, role: "actor")

      added = described_class.tag(active(present: [ maren, korr ]), 1020, logger: logger)
      expect(added).to eq(1)  # only korr added; maren already participating
      roles = ev.event_participants.pluck(:character_id, :role)
      expect(roles).to contain_exactly([ maren.id, "actor" ], [ korr.id, "witness" ])
    end

    it "ignores events outside the scene window" do
      Event.create!(game_time: 500,  scope: "personal", location: tavern, details: {})  # before entry
      Event.create!(game_time: 2000, scope: "personal", location: tavern, details: {})  # after current
      in_window = Event.create!(game_time: 1010, scope: "personal", location: tavern, details: {})

      added = described_class.tag(active(present: [ maren ]), 1020, logger: logger)
      expect(added).to eq(1)
      expect(in_window.event_participants.first.character).to eq(maren)
    end

    it "ignores events at other locations" do
      other_loc = Location.create!(name: "Warehouse", parent: city)
      Event.create!(game_time: 1010, scope: "personal", location: other_loc, details: {})

      added = described_class.tag(active(present: [ maren ]), 1020, logger: logger)
      expect(added).to eq(0)
    end

    it "is a no-op when no characters are present" do
      Event.create!(game_time: 1010, scope: "personal", location: tavern, details: {})
      added = described_class.tag(active(present: []), 1020, logger: logger)
      expect(added).to eq(0)
    end

    it "is a no-op when no events fall in the window" do
      added = described_class.tag(active(present: [ maren ]), 1020, logger: logger)
      expect(added).to eq(0)
    end

    it "tags witnesses on events at scope=local too (not just personal)" do
      ev = Event.create!(game_time: 1010, scope: "local", location: tavern, details: {})
      added = described_class.tag(active(present: [ maren ]), 1020, logger: logger)
      expect(added).to eq(1)
      expect(ev.event_participants.first.role).to eq("witness")
    end

    it "commits in one transaction (all-or-nothing)" do
      ev1 = Event.create!(game_time: 1005, scope: "personal", location: tavern, details: {})
      ev2 = Event.create!(game_time: 1010, scope: "personal", location: tavern, details: {})

      expect {
        described_class.tag(active(present: [ maren, korr ]), 1020, logger: logger)
      }.to change(EventParticipant, :count).by(4)
    end
  end
end
