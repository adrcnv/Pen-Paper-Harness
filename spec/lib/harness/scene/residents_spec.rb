require "rails_helper"

RSpec.describe Harness::Scene::Residents do
  let(:city) { Location.create!(name: "Saltmere") }

  it "calls dead a row that had a body and lost it; a row that never had one is unmaterialised, not dead" do
    corpse = Npc.create!(name: "Korr", location: city, max_hp: 8, current_hp: 0)
    named  = Npc.create!(name: "Eir",  location: city)
    alive  = Npc.create!(name: "Bess", location: city, max_hp: 8, current_hp: 3)
    expect(described_class.deceased?(corpse)).to be(true)
    expect(described_class.deceased?(named)).to be(false)
    expect(described_class.unmaterialized?(named)).to be(true)
    expect(described_class.deceased?(alive)).to be(false)
    expect(described_class.unmaterialized?(alive)).to be(false)
  end
end
