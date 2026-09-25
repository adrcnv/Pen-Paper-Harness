require "rails_helper"

RSpec.describe Harness::Errands do
  let(:town)    { Location.create!(name: "Saltmere") }
  let(:tavern)  { Location.create!(name: "Tavern", parent: town) }
  let!(:player) { Player.create!(name: "Gu", location: tavern, coins: 0) }
  let(:smith)   { Npc.create!(name: "Hrothgar", subrole: "smith", location: tavern, home_location_id: town.id, coins: 10) }
  let(:llm)     { StubLLM.new { @answer || "{}" } }
  let(:ctx)     { Harness::Turn::Context.new(player_location: tavern, game_time: 720, llm_grunt: llm) }

  describe ".bind (what a deed is owed in, at strike)" do
    def bind(terms) = described_class.bind(terms: terms, debtor: smith, context: ctx)

    it "binds a thing the debtor carries to that row, and shows the judge what they carry" do
      axe = Item.create!(name: "hand axe", character: smith)
      @answer = %({"reasoning": "the axe he carries", "is": "thing", "item_id": #{axe.id}, "label": "the axe", "kind": "weapons"})
      expect(bind("Hrothgar brings Gu the axe")).to eq("is" => "thing", "id" => axe.id, "label" => "the axe", "kind" => "weapons")
      expect(llm.user_calls.last).to include("hand axe")
    end

    it "keeps the kind of a thing not yet in hand, to mint at delivery" do
      @answer = %({"reasoning": "a new axe", "is": "thing", "item_id": null, "label": "an axe", "kind": "weapons"})
      expect(bind("Hrothgar forges Gu an axe")).to eq("is" => "thing", "label" => "an axe", "kind" => "weapons")
    end

    it "binds a named person to their row, never the debtor themselves" do
      reeve = Npc.create!(name: "Osric", subrole: "reeve", location: town)
      @answer = %({"reasoning": "fetch the reeve", "is": "person", "item_id": null, "label": "Osric", "kind": null})
      expect(bind("Hrothgar fetches Osric")).to eq("is" => "person", "id" => reeve.id, "label" => "Osric")
      @answer = %({"reasoning": "himself", "is": "person", "item_id": null, "label": "Hrothgar", "kind": null})
      expect(bind("Hrothgar comes himself")).to eq("is" => "work")
    end

    it "realizes a person nobody answers to through the one people pipe — a role reference gets its role, the debtor is the speaker" do
      reeve = Npc.create!(name: "Osric", subrole: "reeve", location: town, current_hp: 5, max_hp: 5)
      allow(Harness::NarrativeShift::Realizer).to receive(:run).and_return({ "character_id" => reeve.id, "minted" => true })
      @answer = %({"reasoning": "fetch the reeve", "is": "person", "item_id": null, "label": "the reeve", "kind": null})
      expect(bind("Hrothgar brings the reeve to Gu by midday")).to eq("is" => "person", "id" => reeve.id, "label" => "the reeve")
      expect(Harness::NarrativeShift::Realizer).to have_received(:run)
        .with(hash_including(claim: { "name" => "the reeve", "subrole" => "reeve", "gist" => "to be brought to the player by Hrothgar: Hrothgar brings the reeve to Gu by midday" }, speaker: smith))
      @answer = %({"reasoning": "fetch Aldred", "is": "person", "item_id": null, "label": "Aldred", "kind": null})
      bind("Hrothgar fetches Aldred")
      expect(Harness::NarrativeShift::Realizer).to have_received(:run).with(hash_including(claim: hash_including("name" => "Aldred")))   # a proper name carries no role
      expect(Harness::NarrativeShift::Realizer).not_to have_received(:run).with(hash_including(claim: hash_including("name" => "Aldred", "subrole" => anything)))
    end

    it "degrades to work: a person the pipe refuses, a thing with neither row nor kind, an unparseable answer, no judge" do
      allow(Harness::NarrativeShift::Realizer).to receive(:run).and_return(nil)
      @answer = %({"reasoning": "nobody", "is": "person", "item_id": null, "label": "the Margrave", "kind": null})
      expect(bind("x")).to eq("is" => "work")
      @answer = %({"reasoning": "?", "is": "thing", "item_id": 999999, "label": "a thing", "kind": null})
      expect(bind("x")).to eq("is" => "work")
      @answer = "not json"
      expect(bind("x")).to eq("is" => "work")
      expect(described_class.bind(terms: "x", debtor: smith, context: nil)).to eq("is" => "work")
    end
  end

  describe ".deliver! (the hand-over at co-presence)" do
    let(:transcript) { Harness::Turn::Transcript.new(input: "x", location_id: tavern.id) }

    def deliver(present = [ smith.id ]) = described_class.deliver!(context: ctx, transcript: transcript, present_ids: present + [ player.id ])
    def errand(attrs) = Obligation.create!({ debtor: smith, creditor: player, kind: "deed", status: "kept", terms: "Hrothgar brings Gu the axe", game_time: 100 }.merge(attrs))
    def names = transcript.tool_calls.map { |tc| tc["name"] }

    it "hands over a carried thing by give_item and settles the row" do
      axe = Item.create!(name: "hand axe", character: smith)
      ob  = errand(subject: { "is" => "thing", "id" => axe.id, "label" => "the axe" })
      deliver
      expect(axe.reload.character_id).to eq(player.id)
      expect(ob.reload.status).to eq("settled")
      expect(names).to eq([ "give_item" ])
    end

    it "mints a thing not yet in hand in the debtor's hands, then gives it" do
      ob = errand(subject: { "is" => "thing", "label" => "an axe", "kind" => "weapons" })
      expect { deliver }.to change(Item, :count).by(1)
      expect(Item.last.character_id).to eq(player.id)
      expect(ob.reload.status).to eq("settled")
      expect(names).to eq([ "give_item" ])
    end

    it "breaks the row when the thing is gone" do
      axe = Item.create!(name: "hand axe", character: smith)
      ob  = errand(subject: { "is" => "thing", "id" => axe.id, "label" => "the axe" })
      axe.destroy!
      deliver
      expect(ob.reload.status).to eq("broken")
      expect(names).to eq([ "errand_broken" ])
    end

    it "pays coins by transfer_coins when the purse allows, marking the receipt settled; breaks it when short" do
      ob = errand(kind: "coins", amount: 4, terms: "Hrothgar pays Gu four coins")
      deliver
      expect(player.reload.coins).to eq(4)
      expect(ob.reload.status).to eq("settled")
      expect(transcript.tool_calls.last).to include("name" => "transfer_coins")
      expect(transcript.tool_calls.last.dig("result", "obligation", "status")).to eq("settled")

      short = errand(kind: "coins", amount: 40, terms: "Hrothgar pays Gu forty coins")
      deliver
      expect(short.reload.status).to eq("broken")
      expect(smith.reload.coins).to eq(6)
      expect(names.last).to eq("errand_broken")
    end

    it "pins a fetched person to the player's place and settles; work settles on the row alone — both leave an event" do
      reeve = Npc.create!(name: "Osric", subrole: "reeve", location: town, home_location_id: town.id, current_hp: 5, max_hp: 5)
      fetch = errand(subject: { "is" => "person", "id" => reeve.id, "label" => "Osric" }, terms: "Hrothgar fetches Osric")
      work  = errand(subject: { "is" => "work" }, terms: "Hrothgar trues the blade")
      expect { deliver }.to change(Event, :count).by(2)
      expect(Harness::Scene::Whereabouts.live_pin_location_id(reeve.reload, 720)).to eq(tavern.id)
      expect([ fetch, work ].map { |o| o.reload.status }).to all(eq("settled"))
      expect(names).to eq(%w[errand_kept errand_kept])
      expect(transcript.tool_calls.first["args"]).to include("brought" => "Osric")
      expect(Event.last.event_participants.pluck(:character_id)).to contain_exactly(smith.id, player.id)
    end

    it "decides a condition-due errand at the meeting once a WHOLE phase has passed since the word — never before" do
      allow(Obligation).to receive(:keep_roll).and_return(0.5)
      miser = Npc.create!(name: "Cenric", subrole: "miller", location: tavern, home_location_id: town.id, properties: { "stance" => "guarded" })
      fresh = errand(status: "open", subject: { "is" => "work" }, game_time: 400)   # struck at 06:40: one boundary (11:00) passed, not the phase after it
      old   = errand(status: "open", subject: { "is" => "work" }, game_time: 100)   # struck before dawn: the dawn phase is over by noon
      cold  = errand(status: "open", subject: { "is" => "work" }, game_time: 100, debtor: miser)
      deliver([ smith.id, miser.id ])
      expect(fresh.reload.status).to eq("open")
      expect(old.reload.status).to eq("settled")
      expect(cold.reload.status).to eq("broken")
      expect(names).to eq([ "errand_kept" ])   # a broken roll leaves no line: they simply have nothing for you
    end

    it "hands a clocked errand over no earlier than it falls due — kept at the window's opening, delivered at the hour" do
      early = errand(subject: { "is" => "work" }, due_time: 800)   # kept, due 13:20; now is noon
      deliver
      expect(early.reload.status).to eq("kept")
      expect(names).to eq([])
      ctx.game_time = 800
      deliver
      expect(early.reload.status).to eq("settled")
    end

    it "leaves a dated open errand to the clock, and an absent debtor's kept one for another day" do
      dated = errand(status: "open", due_time: 5000, subject: { "is" => "work" })
      kept  = errand(subject: { "is" => "work" })
      deliver([])
      expect(kept.reload.status).to eq("kept")
      deliver
      expect(dated.reload.status).to eq("open")
      expect(kept.reload.status).to eq("settled")
    end
  end
end
