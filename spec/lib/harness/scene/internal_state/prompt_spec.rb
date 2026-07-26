require "rails_helper"

RSpec.describe Harness::Scene::InternalState::Prompt do
  let(:loc)     { Location.create!(name: "Market Square") }
  let!(:player) { Player.create!(name: "Gu", location: loc) }
  let(:torvin)  { Npc.create!(name: "Torvin", subrole: "granger", location: loc) }

  it "surfaces open obligations from the character's seat (mechanical agenda candidates)" do
    Obligation.create!(debtor: player, creditor: torvin, kind: "coins", amount: nil,
                       terms: "A share of the barge pay", due: "after the loading", game_time: 0)
    h = described_class.character_hash(torvin)
    expect(h["obligations"]).to eq([ "Gu owes you coins (amount unfixed) — A share of the barge pay — due: after the loading" ])
  end

  it "omits the obligations key when the character has none open" do
    Obligation.create!(debtor: player, creditor: torvin, kind: "coins", amount: 3,
                       terms: "Settled already", status: "settled", game_time: 0)
    expect(described_class.character_hash(torvin)).not_to have_key("obligations")
  end
end
