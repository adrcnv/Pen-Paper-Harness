require "rails_helper"

RSpec.describe Harness::Event::PreFilter::After do
  let(:city)    { Location.create!(name: "Saltmere") }
  let(:tavern)  { Location.create!(name: "Tavern", parent: city) }
  let(:warehouse) { Location.create!(name: "Warehouse", parent: city) }
  let(:elsewhere) { Location.create!(name: "Elsewhere") }

  let(:maren) { Npc.create!(name: "Maren", subrole: "barkeep", location: tavern) }
  let(:korr)    { Npc.create!(name: "Korr",    subrole: "stranger", location: tavern) }

  def event_at(loc, t, scope: "personal", participants: [])
    ev = Event.create!(game_time: t, scope: scope, location: loc, details: {})
    participants.each { |c| EventParticipant.create!(event: ev, character: c, role: "actor") }
    ev
  end

  it "returns events strictly after game_time at same location" do
    before = event_at(tavern, 50)
    after1 = event_at(tavern, 60)
    after2 = event_at(tavern, 70)

    out = described_class.events(game_time: 55, location: tavern, participants: [])
    expect(out.map(&:id)).to contain_exactly(after1.id, after2.id)
  end

  it "includes events at same-parent siblings" do
    here  = event_at(tavern, 100)
    there = event_at(warehouse, 110)  # sibling sublocation
    out = described_class.events(game_time: 50, location: tavern, participants: [])
    expect(out.map(&:id)).to contain_exactly(here.id, there.id)
  end

  it "includes events at the parent (city) location" do
    city_ev = event_at(city, 100)
    out = described_class.events(game_time: 50, location: tavern, participants: [])
    expect(out.map(&:id)).to include(city_ev.id)
  end

  it "excludes events at unrelated locations" do
    here  = event_at(tavern, 100)
    far   = event_at(elsewhere, 110)
    out = described_class.events(game_time: 50, location: tavern, participants: [])
    expect(out.map(&:id)).to contain_exactly(here.id)
  end

  it "includes events involving any of the proposed participants regardless of location" do
    maren; korr
    far_evt = event_at(elsewhere, 110, participants: [ maren ])
    other   = event_at(elsewhere, 120, participants: [ korr ])

    out = described_class.events(game_time: 50, location: tavern, participants: [ maren ])
    expect(out.map(&:id)).to include(far_evt.id)
    expect(out.map(&:id)).not_to include(other.id)
  end

  it "deduplicates events that match both location and participant channels" do
    maren
    ev = event_at(tavern, 100, participants: [ maren ])
    out = described_class.events(game_time: 50, location: tavern, participants: [ maren ])
    expect(out.size).to eq(1)
    expect(out.first.id).to eq(ev.id)
  end

  it "orders by (game_time, id) ascending" do
    a = event_at(tavern, 100)
    b = event_at(tavern, 100)  # same time, later id
    c = event_at(tavern, 110)

    out = described_class.events(game_time: 50, location: tavern, participants: [])
    expect(out.map(&:id)).to eq([ a.id, b.id, c.id ])
  end

  it "respects the limit parameter" do
    20.times { |i| event_at(tavern, 100 + i) }
    out = described_class.events(game_time: 50, location: tavern, participants: [], limit: 5)
    expect(out.size).to eq(5)
  end

  it "with no location and no participants, returns nothing" do
    event_at(tavern, 100)
    out = described_class.events(game_time: 50, location: nil, participants: [])
    expect(out).to be_empty
  end
end
