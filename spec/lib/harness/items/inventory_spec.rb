require "rails_helper"

RSpec.describe Harness::Items::Inventory do
  let(:loc) { Location.create!(name: "Outpost") }

  before  { described_class.reload! }
  after   { described_class.reload! }

  describe ".roll_for_player" do
    it "rolls the deterministic fighter starter kit (longblade + medium_armor)" do
      player = Player.create!(name: "Hero", location: loc, character_class: "fighter")
      items  = described_class.roll_for_player(player, rng: Random.new(1))
      subroles = items.map(&:subrole).sort
      expect(subroles).to eq(%w[longblade medium_armor].sort)
      expect(items.map(&:character_id).uniq).to eq([ player.id ])
    end

    it "rolls starter coins onto the player (within the formula range)" do
      player = Player.create!(name: "Hero", location: loc, character_class: "fighter")
      described_class.roll_for_player(player, rng: Random.new(1))
      # fighter coins = "2d10+10" → range [12, 30].
      expect(player.coins).to be_between(12, 30)
    end

    it "rolls the deterministic mage starter kit (focus + robes)" do
      player = Player.create!(name: "Magus", location: loc, character_class: "mage")
      items  = described_class.roll_for_player(player, rng: Random.new(1))
      expect(items.map(&:subrole).sort).to eq(%w[focus robes])
    end

    it "rolls the ranger three-piece kit (bow + short_blade + light_armor)" do
      player = Player.create!(name: "Tracker", location: loc, character_class: "ranger")
      items  = described_class.roll_for_player(player, rng: Random.new(1))
      expect(items.map(&:subrole).sort).to eq(%w[bow light_armor short_blade])
    end

    it "returns [] for an unknown class without raising" do
      player = Player.create!(name: "Mystery", location: loc, character_class: "alien_warlock")
      expect(described_class.roll_for_player(player)).to eq([])
    end
  end

  describe ".roll_for_npc" do
    it "rolls items consistent with the class table over many seeds" do
      kits = (1..200).map { |seed|
        npc = Npc.create!(name: "F#{seed}", location: loc, character_class: "fighter")
        described_class.roll_for_npc(npc, rng: Random.new(seed))
      }
      sizes = kits.map(&:size)
      # Fighter table: nothing=5, just_weapon=50, armed_armored=35,
      # veteran_kit=9 (with 50% jewelry chance), legendary_outlier=1.
      # Across 200 seeds we expect a mix of 0-, 1-, 2-, 3-piece kits.
      expect(sizes.uniq.size).to be > 1
      expect(sizes.min).to eq(0)
      expect(sizes.max).to be >= 2
    end

    it "fat tail fires — across 500 commoner seeds, at least one rolls legendary_outlier" do
      had_magical = 500.times.any? { |seed|
        npc   = Npc.create!(name: "C#{seed}", location: loc, character_class: "commoner")
        items = described_class.roll_for_npc(npc, rng: Random.new(seed))
        items.any? { |it| Array(it.properties["effects"]).any? }
      }
      expect(had_magical).to be(true), "500 commoner seeds produced 0 magical items — legendary_outlier weight may be miscalibrated"
    end

    it "returns [] for an unknown class without raising" do
      npc = Npc.create!(name: "Stranger", location: loc, character_class: "void_dancer")
      expect(described_class.roll_for_npc(npc)).to eq([])
    end

    it "rolls coins onto the npc regardless of which items were rolled" do
      coins = (1..50).map { |seed|
        npc = Npc.create!(name: "C#{seed}", location: loc, character_class: "commoner")
        described_class.roll_for_npc(npc, rng: Random.new(seed))
        npc.coins
      }
      # commoner coins = "1d6" → range [1, 6]; many seeds should land in there.
      expect(coins.min).to be >= 0
      expect(coins.max).to be <= 6
      expect(coins.uniq.size).to be > 1, "coin rolls should vary across seeds"
    end

    it "all rolled items are owned by the npc (character_id set, location_id nil)" do
      npc   = Npc.create!(name: "Kit", location: loc, character_class: "ranger")
      items = described_class.roll_for_npc(npc, rng: Random.new(7))
      next if items.empty?
      expect(items.map(&:character_id).uniq).to eq([ npc.id ])
      expect(items.map(&:location_id).uniq).to eq([ nil ])
    end
  end

  describe ".roll_starter_coins!" do
    it "adds coins without touching the player's existing items" do
      player = Player.create!(name: "Hero", location: loc, character_class: "rogue")
      Item.create!(name: "rusty knife", character_id: player.id,
                   properties: { "tags" => [ "weapon" ], "modifiers" => [], "effects" => [] })
      before = player.items.pluck(:id)

      amount = described_class.roll_starter_coins!(player, rng: Random.new(2))

      # rogue coins = "3d10+20" → range [23, 50].
      expect(amount).to be_between(23, 50)
      expect(player.reload.coins).to eq(amount)
      expect(player.items.pluck(:id)).to eq(before), "existing items should not have been touched"
    end

    it "returns 0 for an unknown class" do
      player = Player.create!(name: "Mystery", location: loc, character_class: "alien_warlock")
      expect(described_class.roll_starter_coins!(player)).to eq(0)
    end
  end

  describe "validation" do
    it "raises InvalidInventory for unknown library id in a recipe" do
      bad = {
        "fighter" => {
          "rolls" => [ { "name" => "x", "weight" => 1 } ],
          "recipes" => { "x" => [ { "specific" => "this_does_not_exist" } ] }
        }
      }
      stub_yaml(npc: bad)
      expect { described_class.roll_for_npc(Npc.create!(name: "x", location: loc, character_class: "fighter")) }
        .to raise_error(described_class::InvalidInventory, /not in Library/)
    end

    it "raises InvalidInventory when rolls reference missing recipe" do
      bad = {
        "fighter" => {
          "rolls" => [ { "name" => "ghost", "weight" => 1 } ],
          "recipes" => { "other" => [] }
        }
      }
      stub_yaml(npc: bad)
      expect { described_class.roll_for_npc(Npc.create!(name: "x", location: loc, character_class: "fighter")) }
        .to raise_error(described_class::InvalidInventory, /not in recipes/)
    end

    it "raises InvalidInventory when an item lists both specific AND category" do
      bad = {
        "fighter" => {
          "rolls" => [ { "name" => "y", "weight" => 1 } ],
          "recipes" => { "y" => [ { "specific" => "longblade", "category" => "weapons" } ] }
        }
      }
      stub_yaml(npc: bad)
      expect { described_class.roll_for_npc(Npc.create!(name: "x", location: loc, character_class: "fighter")) }
        .to raise_error(described_class::InvalidInventory, /exactly one of `specific` or `category`/)
    end
  end

  def stub_yaml(npc: nil, player: nil)
    allow(YAML).to receive(:safe_load_file).and_call_original
    if npc
      allow(YAML).to receive(:safe_load_file)
        .with(described_class::INVENTORY_DIR.join("npc_inventory.yml"), permitted_classes: [], aliases: false)
        .and_return(npc)
    end
    if player
      allow(YAML).to receive(:safe_load_file)
        .with(described_class::INVENTORY_DIR.join("player_starter.yml"), permitted_classes: [], aliases: false)
        .and_return(player)
    end
    described_class.reload!
  end
end
