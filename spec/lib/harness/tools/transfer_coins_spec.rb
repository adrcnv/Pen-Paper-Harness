require "rails_helper"

RSpec.describe Harness::Tools::TransferCoins do
  let(:loc)     { Location.create!(name: "Saltmere") }
  let(:player)  { Player.create!(name: "Hero",  location: loc, coins: 50) }
  let(:vendor)  { Npc.create!(name: "Marta",    location: loc, character_class: "commoner", coins: 5)  }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 100) }

  describe "schema" do
    it "is a valid Anthropic tool schema" do
      schema = described_class.schema
      expect(schema["name"]).to eq("transfer_coins")
      expect(schema["input_schema"]["required"]).to eq(%w[from_id to_id amount])
    end
  end

  describe "happy path" do
    it "deducts from from, adds to to, logs a personal event with both as participants" do
      expect {
        result = described_class.new.call(
          { "from_id" => player.id, "to_id" => vendor.id, "amount" => 12, "reason" => "ale and lodging" },
          context
        )
        expect(result["error"]).to be_nil
        expect(result["amount"]).to eq(12)
        expect(result["from_balance"]).to eq(38)
        expect(result["to_balance"]).to eq(17)
      }.to change { Event.count }.by(1)

      expect(player.reload.coins).to eq(38)
      expect(vendor.reload.coins).to eq(17)

      ev = Event.order(:id).last
      expect(ev.scope).to eq("personal")
      expect(ev.details["transfer_coins"]).to include("amount" => 12, "reason" => "ale and lodging")
      roles = ev.event_participants.pluck(:character_id, :role).sort
      expect(roles).to include([ player.id, "payer" ], [ vendor.id, "payee" ])
      # The legible past-tense record — the mechanical door owns "paid".
      expect(ev.recall_text).to eq("Hero paid Marta 12 coins — ale and lodging")
    end

    it "uses to.location when from has no location" do
      drifter = Npc.create!(name: "Drifter", location: nil, character_class: "commoner", coins: 100)
      described_class.new.call(
        { "from_id" => drifter.id, "to_id" => player.id, "amount" => 5 },
        context
      )
      expect(Event.order(:id).last.location_id).to eq(loc.id)
    end
  end

  describe "validation" do
    it "rejects missing from_id" do
      out = described_class.new.call({ "to_id" => vendor.id, "amount" => 5 }, context)
      expect(out["error"]).to match(/from_id required/)
    end

    it "rejects missing to_id" do
      out = described_class.new.call({ "from_id" => player.id, "amount" => 5 }, context)
      expect(out["error"]).to match(/to_id required/)
    end

    it "rejects non-positive amount" do
      out = described_class.new.call({ "from_id" => player.id, "to_id" => vendor.id, "amount" => 0 }, context)
      expect(out["error"]).to match(/positive integer/)
    end

    it "rejects negative amount" do
      out = described_class.new.call({ "from_id" => player.id, "to_id" => vendor.id, "amount" => -3 }, context)
      expect(out["error"]).to match(/positive integer/)
    end

    it "rejects same-character transfer" do
      out = described_class.new.call({ "from_id" => player.id, "to_id" => player.id, "amount" => 5 }, context)
      expect(out["error"]).to match(/must differ/)
    end

    it "rejects unknown from_id" do
      out = described_class.new.call({ "from_id" => 999_999, "to_id" => vendor.id, "amount" => 5 }, context)
      expect(out["error"]).to match(/no character with id=999999/)
    end

    it "rejects unknown to_id" do
      out = described_class.new.call({ "from_id" => player.id, "to_id" => 999_999, "amount" => 5 }, context)
      expect(out["error"]).to match(/no character with id=999999/)
    end

    it "rejects insufficient funds without mutating either balance" do
      out = described_class.new.call({ "from_id" => vendor.id, "to_id" => player.id, "amount" => 100 }, context)
      expect(out["error"]).to match(/has only 5 coins/)
      expect(player.reload.coins).to eq(50)
      expect(vendor.reload.coins).to eq(5)
    end
  end

  describe "obligation auto-settle (paying your creditor pays the debt)" do
    it "settles the debt when the payment covers it, and the event says so" do
      ob = Obligation.create!(debtor: player, creditor: vendor, kind: "coins", amount: 12, terms: "For lodging")
      out = described_class.new.call({ "from_id" => player.id, "to_id" => vendor.id, "amount" => 12 }, context)
      expect(out.dig("obligation", "status")).to eq("settled")
      expect(ob.reload.status).to eq("settled")
      expect(Event.order(:id).last.recall_text).to eq("Hero paid Marta 12 coins, settling their bargain (For lodging)")
    end

    it "reduces the debt on a partial payment, and the event carries the remainder" do
      ob = Obligation.create!(debtor: player, creditor: vendor, kind: "coins", amount: 12, terms: "For lodging")
      out = described_class.new.call({ "from_id" => player.id, "to_id" => vendor.id, "amount" => 5 }, context)
      expect(out.dig("obligation", "remaining")).to eq(7)
      expect(ob.reload).to have_attributes(status: "open", amount: 7)
      expect(Event.order(:id).last.recall_text).to eq("Hero paid Marta 5 coins, part of their bargain (7 coins still owed)")
    end

    it "settles an unfixed-amount debt on any payment" do
      ob = Obligation.create!(debtor: player, creditor: vendor, kind: "coins", amount: nil, terms: "A third of the take")
      described_class.new.call({ "from_id" => player.id, "to_id" => vendor.id, "amount" => 3 }, context)
      expect(ob.reload.status).to eq("settled")
    end

    it "leaves unrelated transfers and deed obligations alone" do
      deed  = Obligation.create!(debtor: player, creditor: vendor, kind: "deed", terms: "Haul the grain")
      other = Obligation.create!(debtor: vendor, creditor: player, kind: "coins", amount: 4, terms: "Change owed")
      out = described_class.new.call({ "from_id" => player.id, "to_id" => vendor.id, "amount" => 5 }, context)
      expect(out["obligation"]).to be_nil
      expect(deed.reload.status).to eq("open")
      expect(other.reload.status).to eq("open")
    end
  end
end
