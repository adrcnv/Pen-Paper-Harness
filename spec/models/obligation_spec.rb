require "rails_helper"

RSpec.describe Obligation do
  let(:loc)     { Location.create!(name: "Tavern") }
  let(:wenriel) { Npc.create!(name: "Wenriel", location: loc) }
  let!(:player) { Player.create!(name: "Gu", location: loc) }

  it "rejects unknown kinds and statuses" do
    expect {
      described_class.create!(debtor: player, creditor: wenriel, kind: "favor", terms: "x")
    }.to raise_error(ActiveRecord::RecordInvalid)
    expect {
      described_class.create!(debtor: player, creditor: wenriel, kind: "coins", status: "paid", terms: "x")
    }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "renders line_for from each seat, unfixed amount spelled out" do
    ob = described_class.create!(debtor: player, creditor: wenriel, kind: "coins", amount: nil,
                                 terms: "A third of the take", due: "after the tip pays off")
    expect(ob.line_for(player.id)).to eq("You owe Wenriel coins (amount unfixed) — A third of the take — due: after the tip pays off")
    expect(ob.line_for(wenriel.id)).to eq("Gu owes you coins (amount unfixed) — A third of the take — due: after the tip pays off")
  end

  it "renders a deed without an amount clause" do
    ob = described_class.create!(debtor: wenriel, creditor: player, kind: "deed", terms: "A day's haulage")
    expect(ob.line_for(player.id)).to eq("Wenriel owes you — A day's haulage")
  end
end
