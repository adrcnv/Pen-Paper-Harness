require "rails_helper"

RSpec.describe Player do
  let(:city) { Location.create!(name: "Saltmere") }

  it "persists with type='Player'" do
    p = described_class.create!(name: "Hero", location: city)
    expect(p.type).to eq("Player")
    expect(p).to be_a(Player)
    expect(p).to be_a(Character)
  end

  it "is not returned by Npc.all" do
    described_class.create!(name: "Hero", location: city)
    expect(Npc.all).to be_empty
  end

  it "carries stats like any character" do
    p = described_class.create!(name: "Hero", location: city, strength: 16, charisma: 12)
    expect(p.stat("strength")).to eq(16)
    expect(p.stat("charisma")).to eq(12)
  end

  it "stat() returns the default for nil-statted attributes" do
    p = described_class.create!(name: "Hero", location: city)
    expect(p.stat("strength")).to eq(Character::DEFAULT_STAT_VALUE)
    expect(p.stat("wisdom")).to eq(10)
  end

  it "stat() returns nil for unknown stat names" do
    p = described_class.create!(name: "Hero", location: city)
    expect(p.stat("luck")).to be_nil
  end

  it "Player.instance returns the single player row" do
    described_class.create!(name: "Hero", location: city)
    expect(Player.instance.name).to eq("Hero")
  end

  it "can be an event participant (for resolve)" do
    p = described_class.create!(name: "Hero", location: city)
    ev = Event.create!(game_time: 1, scope: "personal", location: city, details: {})
    EventParticipant.create!(event: ev, character: p, role: "actor")
    expect(p.event_participants.count).to eq(1)
  end

  it "can own items" do
    p = described_class.create!(name: "Hero", location: city)
    Item.create!(name: "sword", subrole: "weapon", character: p)
    expect(p.items.pluck(:name)).to eq([ "sword" ])
  end
end
