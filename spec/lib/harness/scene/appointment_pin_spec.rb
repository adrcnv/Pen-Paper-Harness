require "rails_helper"

RSpec.describe Harness::Scene::AppointmentPin do
  let(:city)    { Location.create!(name: "Othoth") }
  let(:mill)    { Location.create!(name: "the Mill", parent: city) }
  let!(:player) { Player.create!(name: "Jay", location: mill) }
  let!(:haren)  { Npc.create!(name: "Haren", subrole: "miller", location: city, home_location: city) }

  DAWN = 6 * 60

  def meet!(due_time:, location: mill, debtor: haren)
    creditor = debtor == haren ? player : haren
    Obligation.create!(debtor: debtor, creditor: creditor, kind: "meet",
                       terms: "Help unload the herring", due: "dawn",
                       due_time: due_time, game_time: 0, location_id: location.id)
  end

  it "relocates the counterparty to the meeting place within the window" do
    meet!(due_time: DAWN)
    pinned = described_class.pin!(mill, DAWN - 60) # an hour early, within LEAD
    expect(pinned.map(&:id)).to eq([ haren.id ])
    expect(haren.reload.location_id).to eq(mill.id)
  end

  it "pins in either direction (player owes the meet)" do
    meet!(due_time: DAWN, debtor: player)
    described_class.pin!(mill, DAWN)
    expect(haren.reload.location_id).to eq(mill.id)
  end

  it "does not pin outside the lead window or after the breach grace" do
    meet!(due_time: DAWN)
    described_class.pin!(mill, DAWN - Harness::Scene::AppointmentPin::LEAD - 60)
    expect(haren.reload.location_id).to eq(city.id)
    described_class.pin!(mill, DAWN + Obligation::BREACH_GRACE + 60)
    expect(haren.reload.location_id).to eq(city.id)
  end

  it "does not pin at a different location than the deal was struck" do
    docks = Location.create!(name: "the Docks", parent: city)
    meet!(due_time: DAWN, location: docks)
    described_class.pin!(mill, DAWN)
    expect(haren.reload.location_id).to eq(city.id)
  end

  it "ignores settled/broken meets, the dead, and a missing clock" do
    meet!(due_time: DAWN).update!(status: "broken")
    described_class.pin!(mill, DAWN)
    expect(haren.reload.location_id).to eq(city.id)

    meet!(due_time: DAWN)
    haren.update!(max_hp: 5, current_hp: 0)
    expect(described_class.pin!(mill, DAWN)).to eq([])
    expect(described_class.pin!(mill, nil)).to eq([])
  end

  it "is a no-op when the counterparty is already there" do
    haren.update!(location_id: mill.id)
    meet!(due_time: DAWN)
    expect(described_class.pin!(mill, DAWN)).to eq([])
  end
end
