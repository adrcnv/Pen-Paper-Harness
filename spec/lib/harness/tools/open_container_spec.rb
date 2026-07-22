require "rails_helper"

RSpec.describe Harness::Tools::OpenContainer do
  let(:loc)     { Location.create!(name: "Vault", x: 1.0, y: 1.0, biome: "lowland") }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 100) }
  let!(:player) { Player.create!(name: "Hero", location: loc, coins: 0, dexterity: 14) }
  let(:chest)   { Harness::Treasure::Chest.place(location: loc, rarity: "uncommon", rng: Random.new(1)) }

  def open(args = {})
    described_class.new.call({ "item_id" => chest.id }.merge(args), context)
  end

  context "with a guaranteed-success lock roll (high DEX, stubbed crit)" do
    before { allow(Harness::Dice).to receive(:check).and_return(Harness::Dice::Outcome.new(result: "success", roll: 20, against: 15)) }

    it "reveals contents to the floor and coins to the opener" do
      out = open
      expect(out["opened"]).to be(true)
      expect(out["items"]).not_to be_empty
      expect(out["coins_found"]).to be > 0
      expect(player.reload.coins).to eq(out["coins_found"])
      # contents are now real floor items at the location
      expect(Item.where(location_id: loc.id).where.not(id: chest.id).count).to eq(out["items"].size)
      expect(chest.reload.properties["state"]).to eq("open")
      expect(chest.properties).not_to have_key("locked")
      expect(chest.properties).not_to have_key("loot")
    end
  end

  context "check XP on the pick" do
    before { allow(Harness::Dice).to receive(:check).and_return(Harness::Dice::Outcome.new(result: "success", roll: 18, against: 20)) }

    it "pays the lock's difficulty tier once, on the successful pick" do
      chest.update!(properties: chest.properties.merge("locked" => "hard"))
      out = open
      expect(out["xp_gained"]).to eq(15)
      expect(player.reload.xp).to eq(15)
    end

    it "pays nothing for an unlocked chest" do
      chest.update!(properties: chest.properties.except("locked"))
      out = open
      expect(out["opened"]).to be(true)
      expect(out["xp_gained"]).to be_nil
      expect(player.reload.xp).to eq(0)
    end
  end

  context "with a failed lock roll" do
    before { allow(Harness::Dice).to receive(:check).and_return(Harness::Dice::Outcome.new(result: "failure", roll: 3, against: 15)) }

    it "leaves the chest closed and reveals nothing (retry allowed)" do
      out = open
      expect(out["opened"]).to be(false)
      expect(out["locked"]).to be(true)
      expect(chest.reload.properties["state"]).to eq("closed")
      expect(Item.where(location_id: loc.id).where.not(id: chest.id)).to be_empty
      expect(player.reload.coins).to eq(0)
    end

    it "advances the clock (lockpicking takes time)" do
      expect { open }.to change { context.game_time }.by(Harness::Tools::OpenContainer::PICK_MINUTES)
    end
  end

  it "rejects a non-container item" do
    plain = Item.create!(name: "rock", subrole: "t", location: loc, properties: { "tags" => [] })
    out = described_class.new.call({ "item_id" => plain.id }, context)
    expect(out["error"]).to match(/not a container/)
  end

  it "rejects opening when the actor isn't where the chest is" do
    player.update!(location: Location.create!(name: "Elsewhere"))
    out = open
    expect(out["error"]).to match(/not where/)
  end

  it "rejects re-opening an already-open chest" do
    chest.update!(properties: chest.properties.merge("state" => "open"))
    out = open
    expect(out["error"]).to match(/already open/)
  end
end
