require "rails_helper"

RSpec.describe Harness::Items::LocationSeeder do
  before  { described_class.reload! }
  after   { described_class.reload! }

  describe ".bucket_for" do
    it "returns 'city' for top-level worldgen city" do
      city = Location.create!(name: "Saltmere", x: 100, y: 100)
      expect(described_class.bucket_for(city)).to eq("city")
    end

    it "returns 'sublocation' for child locations" do
      city = Location.create!(name: "Saltmere", x: 100, y: 100)
      sub  = Location.create!(name: "Tavern", parent_id: city.id)
      expect(described_class.bucket_for(sub)).to eq("sublocation")
    end

    it "returns 'encounter_combat' for wilderness_leaf with encounter_type=combat" do
      leaf = Location.create!(name: "Bandit defile",
                              x: 50, y: 50,
                              properties: { "kind" => "wilderness_leaf", "encounter_type" => "combat" })
      expect(described_class.bucket_for(leaf)).to eq("encounter_combat")
    end

    it "returns 'encounter_discovery' for wilderness_leaf with encounter_type=discovery" do
      leaf = Location.create!(name: "Hermit cave",
                              x: 50, y: 50,
                              properties: { "kind" => "wilderness_leaf", "encounter_type" => "discovery" })
      expect(described_class.bucket_for(leaf)).to eq("encounter_discovery")
    end

    it "returns nil for wilderness_leaf without encounter_type" do
      leaf = Location.create!(name: "Wayshrine", x: 50, y: 50,
                              properties: { "kind" => "wilderness_leaf" })
      expect(described_class.bucket_for(leaf)).to be_nil
    end

    it "returns nil for top-level locations without coords (test fixtures)" do
      l = Location.create!(name: "Nowhere")
      expect(described_class.bucket_for(l)).to be_nil
    end
  end

  describe ".seed!" do
    let(:city) { Location.create!(name: "Saltmere", x: 100, y: 100) }
    let(:sub)  { Location.create!(name: "Vault", parent_id: city.id) }

    it "anchors any rolled items to the location" do
      created = (1..40).flat_map { |seed|
        loc = Location.create!(name: "Sub#{seed}", parent_id: city.id)
        described_class.seed!(loc, rng: Random.new(seed))
      }
      next if created.empty?
      expect(created).to all(satisfy { |it| it.location_id.present? && it.character_id.nil? })
    end

    it "marks items_seeded=true after seeding so re-entry is a no-op" do
      first  = described_class.seed!(sub, rng: Random.new(1))
      sub.reload
      expect(sub.properties["items_seeded"]).to be(true)
      first_ids = first.map(&:id)
      second = described_class.seed!(sub, rng: Random.new(99))
      expect(second).to eq([])
      # original items still anchored.
      expect(::Item.where(location_id: sub.id).pluck(:id)).to eq(first_ids)
    end

    it "marks items_seeded=true even when the rolled recipe is `nothing` (no items)" do
      empty_leaf = Location.create!(name: "Quiet stretch", x: 50, y: 50,
                                    properties: { "kind" => "wilderness_leaf", "encounter_type" => "social" })
      result = described_class.seed!(empty_leaf, rng: Random.new(1))
      expect(result).to eq([])
      expect(empty_leaf.reload.properties["items_seeded"]).to be(true)
      # second call also returns [].
      expect(described_class.seed!(empty_leaf)).to eq([])
    end

    it "is a no-op when bucket_for returns nil but still marks the row" do
      orphan = Location.create!(name: "Edge case")
      result = described_class.seed!(orphan, rng: Random.new(0))
      expect(result).to eq([])
      expect(orphan.reload.properties["items_seeded"]).to be(true)
    end

    it "is a no-op for nil location" do
      expect(described_class.seed!(nil)).to eq([])
    end

    it "combat-encounter recipes produce a weapon most of the time" do
      with_weapon = (1..30).count { |seed|
        leaf = Location.create!(name: "Defile#{seed}", x: 50, y: 50,
                                properties: { "kind" => "wilderness_leaf", "encounter_type" => "combat" })
        items = described_class.seed!(leaf, rng: Random.new(seed))
        items.any? { |it| Array(it.properties["tags"]).include?("weapon") }
      }
      # combat table guarantees at least one item per fire (no `nothing`
      # outcome); weapon presence depends on chance gates per recipe.
      expect(with_weapon).to be >= 15
    end
  end

  describe "validation" do
    it "rejects YAML with an unknown library id" do
      bad = { "city" => { "rolls"   => [ { "name" => "x", "weight" => 1 } ],
                          "recipes" => { "x" => [ { "specific" => "absolutely_not_a_thing" } ] } } }
      stub_yaml(bad)
      expect { described_class.seed!(Location.create!(name: "X", x: 0, y: 0)) }
        .to raise_error(described_class::InvalidSeeder, /not in Library/)
    end

    it "rejects YAML referencing missing recipe" do
      bad = { "city" => { "rolls" => [ { "name" => "ghost", "weight" => 1 } ], "recipes" => {} } }
      stub_yaml(bad)
      expect { described_class.seed!(Location.create!(name: "X", x: 0, y: 0)) }
        .to raise_error(described_class::InvalidSeeder, /not in recipes/)
    end
  end

  def stub_yaml(table)
    allow(YAML).to receive(:safe_load_file)
      .with(described_class::SEEDER_PATH, permitted_classes: [], aliases: false)
      .and_return(table)
    described_class.reload!
  end
end
