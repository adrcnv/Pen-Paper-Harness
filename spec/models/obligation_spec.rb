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

    it "parses the wordings the terms judge actually writes: phase-first tomorrow, a day count at a phase, before dark, this afternoon" do
      expect(described_class.parse_due("Midday tomorrow", now)).to eq(71 * 1440 + 720)
      expect(described_class.parse_due("by dusk tomorrow", now)).to eq(71 * 1440 + 1020)
      expect(described_class.parse_due("two days from now at dusk", now)).to eq(72 * 1440 + 1020)
      expect(described_class.parse_due("in two days", now)).to eq(now + 2 * 1440)
      expect(described_class.parse_due("before dark", now)).to eq(70 * 1440 + 1320)
      expect(described_class.parse_due("by dusk today", now)).to eq(70 * 1440 + 1020)
      expect(described_class.parse_due("this afternoon", now)).to eq(70 * 1440 + 840)
      expect(described_class.parse_due("dawn on the third day", now)).to eq(72 * 1440 + 360)
      expect(described_class.parse_due("the third day at dawn", now)).to eq(72 * 1440 + 360)
      expect(described_class.parse_due("the next day", now)).to eq(71 * 1440 + 720)
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
      expect(broken.line_for(wenriel.id, now: 2000)).to eq("Gu owes you — Meet at the mill — due: dawn — BROKEN — Gu never came")
    end

    # Whereabouts always brings the NPC to the meeting place for the window,
    # so a breach is the player's absence — whichever seat owed the meeting.
    it "attributes a breach to the player from every seat, even when the NPC was the debtor" do
      npc_owed = described_class.create!(debtor: wenriel, creditor: player, kind: "meet",
                                         terms: "Meet at the mill", status: "broken")
      expect(npc_owed.line_for(player.id)).to eq("Wenriel owes you — Meet at the mill — BROKEN — you never came")
      expect(npc_owed.line_for(wenriel.id, name: "Wenriel")).to eq("Wenriel owes Gu — Meet at the mill — BROKEN — Gu never came")

      player_owed = described_class.create!(debtor: player, creditor: wenriel, kind: "meet",
                                            terms: "Meet at the docks", status: "broken")
      expect(player_owed.line_for(player.id)).to eq("You owe Wenriel — Meet at the docks — BROKEN — you never came")
      expect(player_owed.line_for(wenriel.id)).to eq("Gu owes you — Meet at the docks — BROKEN — Gu never came")
    end

    it "renders without urgency when no clock is given" do
      ob = described_class.create!(debtor: player, creditor: wenriel, kind: "meet",
                                   terms: "Help unload", due: "tomorrow dawn", due_time: 1800)
      expect(ob.line_for(player.id)).to eq("You owe Wenriel — Help unload — due: tomorrow dawn")
    end
  end

  it "shows a kept errand's resolve to the debtor's own seat only, and a broken one as never made good from either seat" do
    kept = described_class.create!(debtor: wenriel, creditor: player, kind: "deed", terms: "Bring the axe", status: "kept")
    expect(kept.line_for(wenriel.id, name: "Wenriel")).to eq("Wenriel owes Gu — Bring the axe — KEPT — will make good when it falls due")
    expect(kept.line_for(player.id)).to eq("Wenriel owes you — Bring the axe")   # the player's sheet does not leak the roll
    broken = described_class.create!(debtor: wenriel, creditor: player, kind: "coins", amount: 2, terms: "Two coins", status: "broken")
    expect(broken.line_for(player.id)).to eq("Wenriel owes you 2 coins — Two coins — BROKEN — Wenriel never made good")
    expect(broken.line_for(wenriel.id)).to eq("You owe Gu 2 coins — Two coins — BROKEN — you never made good")
  end

  describe ".sweep_dues! (errands owed to the player resolve at due)" do
    let(:now) { 10_000 }
    # A roll of .5: neutral (.7) keeps, guarded (.4) does not.
    before { allow(described_class).to receive(:keep_roll).and_return(0.5) }

    it "keeps an errand once its due window opens, from the debtor's standing; kept stays outstanding but not open" do
      deed = described_class.create!(debtor: wenriel, creditor: player, kind: "deed", terms: "Bring the axe", due_time: now + 60)
      described_class.sweep_dues!(now)
      expect(deed.reload.status).to eq("kept")
      expect(described_class.outstanding).to include(deed)
      expect(described_class.open_now).not_to include(deed)
    end

    it "leaves a failed roll open through the grace, then breaks it" do
      wenriel.update!(properties: { "stance" => "guarded" })
      deed = described_class.create!(debtor: wenriel, creditor: player, kind: "deed", terms: "Bring the axe", due_time: now - 100)
      described_class.sweep_dues!(now)
      expect(deed.reload.status).to eq("open")
      described_class.sweep_dues!(now + 300)
      expect(deed.reload.status).to eq("broken")
    end

    it "salts the roll with the terms, never a bare id (ids repeat from one world to the next)" do
      deed = described_class.create!(debtor: wenriel, creditor: player, kind: "deed", terms: "Bring the axe", due_time: now)
      expect(described_class).to receive(:keep_roll).with("#{deed.id}:Bring the axe").and_call_original
      deed.keeps?
    end

    it "a warmer standing keeps what a colder one would not — the same roll, a moved threshold" do
      wenriel.update!(properties: { "stance" => "guarded" })
      deed = described_class.create!(debtor: wenriel, creditor: player, kind: "deed", terms: "Bring the axe", due_time: now)
      expect(deed.keeps?).to be(false)
      wenriel.update!(properties: { "stance" => "trusting" })
      expect(deed.reload.keeps?).to be(true)
    end

    it "touches neither the player's own debts, a condition-due, an unfixed coin sum, nor a window not yet open" do
      mine    = described_class.create!(debtor: player, creditor: wenriel, kind: "deed", terms: "Haul the grain", due_time: now - 1000)
      someday = described_class.create!(debtor: wenriel, creditor: player, kind: "deed", terms: "After the barge is loaded")
      unfixed = described_class.create!(debtor: wenriel, creditor: player, kind: "coins", terms: "A share", due_time: now - 1000)
      not_yet = described_class.create!(debtor: wenriel, creditor: player, kind: "coins", amount: 2, terms: "Two coins", due_time: now + 500)
      described_class.sweep_dues!(now)
      expect([ mine, someday, unfixed, not_yet ].map { |o| o.reload.status }).to all(eq("open"))
    end
  end
end
