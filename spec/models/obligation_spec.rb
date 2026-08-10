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

  describe ".parse_due (the forward-time parser)" do
    # now = day 70, 08:00 (100_800 + 480)
    let(:now) { 70 * 1440 + 480 }

    it "parses 'tomorrow dawn' to next day's dawn" do
      expect(described_class.parse_due("tomorrow dawn", now)).to eq(71 * 1440 + 360)
    end

    it "parses bare 'tomorrow' to next day's midday (neutral middle)" do
      expect(described_class.parse_due("tomorrow", now)).to eq(71 * 1440 + 720)
    end

    it "parses a bare phase to its NEXT occurrence" do
      expect(described_class.parse_due("at dusk", now)).to eq(70 * 1440 + 1020)  # still ahead today
      expect(described_class.parse_due("by dawn", now)).to eq(71 * 1440 + 360)   # 08:00 is past dawn → tomorrow
    end

    it "parses 'tonight' and 'in two hours' and 'within the hour'" do
      expect(described_class.parse_due("tonight", now)).to eq(70 * 1440 + 1320)
      expect(described_class.parse_due("in two hours", now)).to eq(now + 120)
      expect(described_class.parse_due("within the hour", now)).to eq(now + 60)
    end

    it "parses 'N units from now' (the wording the reflection actually emits)" do
      expect(described_class.parse_due("7 hours from now", now)).to eq(now + 420)
      expect(described_class.parse_due("seven hours from now", now)).to eq(now + 420)
      expect(described_class.parse_due("a day from now", now)).to eq(now + 1440)
    end

    it "returns nil for condition-dues, blanks, and bare units" do
      expect(described_class.parse_due("after the barge is loaded", now)).to be_nil
      expect(described_class.parse_due("hour", now)).to be_nil
      expect(described_class.parse_due(nil, now)).to be_nil
      expect(described_class.parse_due("", now)).to be_nil
    end
  end

  describe ".sweep_breaches! (missed meetings break)" do
    let(:now) { 10_000 }

    it "breaks an open meet past due + grace, leaves coins and in-grace meets alone" do
      missed   = described_class.create!(debtor: player, creditor: wenriel, kind: "meet",
                                         terms: "Meet at the mill", due: "dawn", due_time: now - 300)
      in_grace = described_class.create!(debtor: player, creditor: wenriel, kind: "meet",
                                         terms: "Meet at the docks", due: "dusk", due_time: now - 100)
      coins    = described_class.create!(debtor: player, creditor: wenriel, kind: "coins", amount: 5,
                                         terms: "Five owed", due: "dawn", due_time: now - 9_000)
      undated  = described_class.create!(debtor: player, creditor: wenriel, kind: "meet",
                                         terms: "Meet someday")
      described_class.sweep_breaches!(now)
      expect(missed.reload.status).to eq("broken")
      expect(in_grace.reload.status).to eq("open")
      expect(coins.reload.status).to eq("open")
      expect(undated.reload.status).to eq("open")
    end

    it "keeps broken rows in outstanding but out of open_now" do
      ob = described_class.create!(debtor: player, creditor: wenriel, kind: "meet",
                                   terms: "Meet at the mill", status: "broken")
      expect(described_class.outstanding).to include(ob)
      expect(described_class.open_now).not_to include(ob)
    end
  end

  describe "line_for urgency (computed at read, never stored)" do
    it "renders time-to-due, overdue, and breach" do
      future = described_class.create!(debtor: player, creditor: wenriel, kind: "meet",
                                       terms: "Help unload", due: "tomorrow dawn", due_time: 1440 + 360)
      expect(future.line_for(player.id, now: 480)).to eq("You owe Wenriel — Help unload — due: tomorrow dawn (in 22 hours)")
      expect(future.line_for(player.id, now: 1440 + 300)).to eq("You owe Wenriel — Help unload — due: tomorrow dawn (within the hour)")

      overdue = described_class.create!(debtor: player, creditor: wenriel, kind: "coins", amount: 5,
                                        terms: "Five owed", due: "dawn", due_time: 360)
      expect(overdue.line_for(player.id, now: 2000)).to eq("You owe Wenriel 5 coins — Five owed — due: dawn (OVERDUE)")

      broken = described_class.create!(debtor: player, creditor: wenriel, kind: "meet",
                                       terms: "Meet at the mill", due: "dawn", due_time: 360, status: "broken")
      expect(broken.line_for(wenriel.id, now: 2000)).to eq("Gu owes you — Meet at the mill — due: dawn — BROKEN — never honoured")
    end

    it "renders without urgency when no clock is given" do
      ob = described_class.create!(debtor: player, creditor: wenriel, kind: "meet",
                                   terms: "Help unload", due: "tomorrow dawn", due_time: 1800)
      expect(ob.line_for(player.id)).to eq("You owe Wenriel — Help unload — due: tomorrow dawn")
    end
  end
end
