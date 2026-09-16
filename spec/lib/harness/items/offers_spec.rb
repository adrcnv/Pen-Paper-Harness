require "rails_helper"

RSpec.describe Harness::Items::Offers do
  let(:city)   { Location.create!(name: "Norddal", x: 1.0, y: 1.0, biome: "lowland", properties: { "kind" => "city", "economic_basis" => "herding", "size" => "hamlet", "wealth" => "modest" }) }
  let(:hut)    { Location.create!(name: "the Market Hut", parent: city) }
  let(:tanner) { Npc.create!(name: "Eldri", subrole: "tanner", location: hut) }

  describe ".categories_for" do
    it "reads the trade by keyword, adds a staffed venue's shop stock, and gives most people nothing" do
      expect(described_class.categories_for(tanner, hut)).to eq([ "goods" ])
      expect(described_class.categories_for(Npc.create!(name: "Ora", subrole: "charcoal_merchant", location: hut), hut)).to eq(%w[goods provisions])
      expect(described_class.categories_for(Npc.create!(name: "Wat", subrole: "labourer", location: hut), hut)).to eq([])
      shop   = Location.create!(name: "the Smithy", parent: city, properties: { "shop" => %w[weapons armor] })
      keeper = Npc.create!(name: "Bram", subrole: "labourer", location: shop, home_location_id: shop.id)
      expect(described_class.categories_for(keeper, shop)).to eq(%w[weapons armor])
    end
  end

  describe ".categories_for — unmapped trades" do
    it "an unmapped trade sells what the settlement produces; the tableless stay tableless" do
      salt_town = Location.create!(name: "Bal Vale", x: 2.0, y: 2.0, biome: "lowland", properties: { "kind" => "city", "economic_basis" => "salt", "size" => "hamlet", "wealth" => "poor" })
      salter = Npc.create!(name: "Bess", subrole: "salt worker", location: salt_town)
      expect(described_class.categories_for(salter, salt_town)).to eq([ "goods" ])
      expect(described_class.categories_for(Npc.create!(name: "Ord", subrole: "labourer", location: salt_town), salt_town)).to eq([])
      expect(described_class.categories_for(Npc.create!(name: "Hal", subrole: "guard", location: salt_town), salt_town)).to eq([])
    end
  end

  describe ".clean_label" do
    it "keeps the character's word minus the article, and refuses non-names" do
      expect(described_class.clean_label("a fox pelt")).to eq("fox pelt")
      expect(described_class.clean_label("  the  length of rope ")).to eq("length of rope")
      expect(described_class.clean_label("")).to be_nil
      expect(described_class.clean_label("x" * 41)).to be_nil
    end
  end

  describe ".materialize!" do
    it "on the table: anchored here, for sale, seller recorded, kind chosen by the word, budget stamped, worth a few coins" do
      item = described_class.materialize!(tanner, category: "goods", label: "a fox pelt", game_time: 600, at: hut)
      expect(item.name).to eq("fox pelt")
      expect(item.subrole).to eq("hide")
      expect(item.location_id).to eq(hut.id)
      expect(item.properties).to include("for_sale" => true, "seller_id" => tanner.id)
      expect(described_class.on_table(tanner, hut)).to eq(1)
      expect(described_class.brought_out(tanner.reload, 600)).to eq(1)
      expect(Harness::Items::Value.of(item)).to eq(3)
    end

    it "in someone's hands: owned, not for sale" do
      hero = Player.create!(name: "Hero", location: hut)
      item = described_class.materialize!(tanner, category: "goods", label: "a leather strap", game_time: 600, to: hero)
      expect(item.character_id).to eq(hero.id)
      expect(item.location_id).to be_nil
      expect(item.properties).not_to include("for_sale")
    end

    it "the budget is per clock phase and the stamp keeps only the current phase" do
      described_class::PHASE_CAP.times { described_class.materialize!(tanner, category: "goods", label: "pelt", game_time: 600, at: hut) }
      expect(described_class.budget_left?(tanner.reload, 600)).to be(false)
      expect(described_class.budget_left?(tanner, 600 + 12 * 60)).to be(true)
      described_class.stamp!(tanner, 600 + 12 * 60)
      expect(tanner.reload.properties["brought_out"].keys.size).to eq(1)
    end
  end

  describe ".materialize_described!" do
    it "reads the painted object out of a figure's description and puts it on their table; nothing known, nothing minted" do
      item = described_class.materialize_described!(tanner, "an old man balancing a wheel of cheese on his knee", hut, 600)
      expect(item.name).to end_with("wheel of cheese")
      expect(item.properties).to include("for_sale" => true, "seller_id" => tanner.id)
      expect(described_class.materialize_described!(tanner, "a young boy stacking kindling near the hearth", hut, 600)).to be_nil
    end
  end

  describe "Library.template_for" do
    it "matches the kind by a word of the label, else falls back to a weighted pick" do
      expect(Harness::Items::Library.template_for("goods", label: "a coil of rope")["id"]).to eq("cordage")
      expect(Harness::Items::Library.template_for("provisions", label: "small beer")["id"]).to eq("drink")
      expect(Harness::Items::Library.template_for("goods", label: "something odd", rng: Random.new(1))).to be_a(Hash)
    end
  end
end
