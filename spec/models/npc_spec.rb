require "rails_helper"

RSpec.describe Npc do
  let(:city) { Location.create!(name: "Saltmere") }

  it "persists with type='Npc'" do
    npc = described_class.create!(name: "Maren", subrole: "barkeep", location: city)
    expect(npc.type).to eq("Npc")
    expect(npc).to be_a(Npc)
    expect(npc).to be_a(Character)
  end

  it "is found by Npc.all but excluded from Player.all" do
    described_class.create!(name: "F", subrole: "x", location: city)
    Player.create!(name: "P", location: city)
    expect(Npc.all.pluck(:name)).to eq([ "F" ])
    expect(Player.all.pluck(:name)).to eq([ "P" ])
    expect(Character.count).to eq(2)
  end

  it "carries nullable stat columns" do
    npc = described_class.create!(name: "F", subrole: "x", location: city)
    expect(npc.strength).to be_nil
    npc.update!(strength: 14, charisma: 8)
    expect(npc.reload.strength).to eq(14)
    expect(npc.charisma).to eq(8)
  end
end
