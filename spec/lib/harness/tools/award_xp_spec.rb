require "rails_helper"

RSpec.describe Harness::Tools::AwardXP do
  let(:loc)     { Location.create!(name: "Hall") }
  let(:player)  { Player.create!(name: "Hero", location: loc, character_class: "fighter", level: 1, xp: 0, constitution: 12) }
  let(:npc)     { Npc.create!(name: "Marta", location: loc, character_class: "commoner") }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 100) }

  describe "schema" do
    it "is a valid tool schema with required fields" do
      schema = described_class.schema
      expect(schema["name"]).to eq("award_xp")
      expect(schema["input_schema"]["required"]).to eq(%w[character_id amount reason])
    end
  end

  describe "happy path" do
    it "awards XP to the player, logs an event, surfaces totals" do
      expect {
        out = described_class.new.call(
          { "character_id" => player.id, "amount" => 25, "reason" => "solved Elder Harrow's missing-grandson arc" },
          context
        )
        expect(out["error"]).to be_nil
        expect(out["amount"]).to eq(25)
        expect(out["xp_total"]).to eq(25)
        expect(out["leveled_up"]).to be(false)
      }.to change { Event.count }.by(1)

      expect(player.reload.xp).to eq(25)
      ev = Event.order(:id).last
      expect(ev.scope).to eq("personal")
      expect(ev.details["award_xp"]).to include("amount" => 25, "reason" => "solved Elder Harrow's missing-grandson arc")
    end

    it "auto-levels-up when the threshold is crossed" do
      # threshold_for(2) = 100. Give 100 in one shot.
      out = described_class.new.call(
        { "character_id" => player.id, "amount" => 50, "reason" => "first big win" },
        context
      )
      out2 = described_class.new.call(
        { "character_id" => player.id, "amount" => 50, "reason" => "second big win" },
        context
      )
      expect(out2["leveled_up"]).to be(true)
      expect(out2["new_level"]).to eq(2)
      expect(player.reload.level).to eq(2)
    end

    it "clamps amount above MAX_PER_CALL" do
      out = described_class.new.call(
        { "character_id" => player.id, "amount" => 999, "reason" => "epic" },
        context
      )
      expect(out["amount"]).to eq(described_class::MAX_PER_CALL)
      expect(player.reload.xp).to eq(described_class::MAX_PER_CALL)
    end
  end

  describe "validation" do
    it "rejects missing character_id" do
      out = described_class.new.call({ "amount" => 5, "reason" => "x" }, context)
      expect(out["error"]).to match(/character_id required/)
    end

    it "rejects non-positive amount" do
      out = described_class.new.call({ "character_id" => player.id, "amount" => 0, "reason" => "x" }, context)
      expect(out["error"]).to match(/positive integer/)
    end

    it "rejects negative amount" do
      out = described_class.new.call({ "character_id" => player.id, "amount" => -5, "reason" => "x" }, context)
      expect(out["error"]).to match(/positive integer/)
    end

    it "rejects empty reason" do
      out = described_class.new.call({ "character_id" => player.id, "amount" => 10, "reason" => "" }, context)
      expect(out["error"]).to match(/reason/)
    end

    it "rejects unknown character_id" do
      out = described_class.new.call({ "character_id" => 999_999, "amount" => 10, "reason" => "x" }, context)
      expect(out["error"]).to match(/no character with id=999999/)
    end

    it "rejects awards to non-Player characters" do
      out = described_class.new.call({ "character_id" => npc.id, "amount" => 10, "reason" => "x" }, context)
      expect(out["error"]).to match(/targets the player only/)
      expect(npc.reload.xp).to eq(0)
    end
  end
end
