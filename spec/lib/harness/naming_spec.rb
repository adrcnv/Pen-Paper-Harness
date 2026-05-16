require "rails_helper"

RSpec.describe Harness::Naming do
  let(:kingdom) { Faction.create!(name: "Boreas", subrole: "kingdom", is_kingdom: true, properties: { "culture_id" => "nord" }) }
  let(:city)    { Location.create!(name: "Stenholm", parent: nil, x: 1.0, y: 1.0, biome: "highland", faction: kingdom) }
  let(:sub)     { Location.create!(name: "The Mead Hall", parent: city) }

  describe ".kingdom_for" do
    it "finds the kingdom at the top-level ancestor" do
      expect(described_class.kingdom_for(sub)).to eq(kingdom)
      expect(described_class.kingdom_for(city)).to eq(kingdom)
    end

    it "returns nil when no ancestor has an is_kingdom faction" do
      orphan_city = Location.create!(name: "Drift", parent: nil)
      expect(described_class.kingdom_for(orphan_city)).to be_nil
    end

    it "returns nil when faction is non-kingdom" do
      guild = Faction.create!(name: "Smiths", subrole: "guild", is_kingdom: false)
      city  = Location.create!(name: "Forgewall", parent: nil, faction: guild)
      expect(described_class.kingdom_for(city)).to be_nil
    end
  end

  describe ".culture_for" do
    it "resolves to the culture hash via the kingdom's culture_id" do
      culture = described_class.culture_for(sub)
      expect(culture["id"]).to eq("nord")
    end

    it "returns nil when kingdom has no culture_id" do
      kingdom.update!(properties: kingdom.properties.except("culture_id"))
      expect(described_class.culture_for(sub)).to be_nil
    end
  end

  describe ".for" do
    it "uses the kingdom's culture pool when available" do
      nord = Harness::Naming::Library.find("nord")
      30.times do
        name   = described_class.for(location: sub, rng: Random.new(0))
        # Given the rng is fixed, the same name should come out — guard against drift.
        given, family = name.split(" ", 2)
        expect(nord["given"]).to include(given)
        expect(nord["family"]).to include(family) if family
      end
    end

    it "falls back to default culture when no kingdom resolves" do
      orphan = Location.create!(name: "Nowhere", parent: nil)
      name = described_class.for(location: orphan, rng: Random.new(0))
      given, family = name.split(" ", 2)
      default = Harness::Naming::Library.default
      expect(default["given"]).to include(given)
      expect(default["family"]).to include(family) if family
    end

    it "produces stable names with a fixed rng" do
      rng = Random.new(42)
      a = described_class.for(location: sub, rng: rng)
      rng = Random.new(42)
      b = described_class.for(location: sub, rng: rng)
      expect(a).to eq(b)
    end
  end

  describe ".unique_for" do
    it "returns a name not present in Character.name" do
      name = described_class.unique_for(location: sub, rng: Random.new(0))
      expect(Character.exists?(name: name)).to be(false)
    end

    it "falls back to a Roman-numeral suffix when every retry collides" do
      # Force collision: pre-populate Character with every name a tiny single-entry
      # pool could produce. Stub the culture to a 1-entry pool so all retries collide.
      stub_culture = { "id" => "tiny", "given" => [ "Aex" ], "family" => [] }
      allow(Harness::Naming::Library).to receive(:default).and_return(stub_culture)
      allow(described_class).to receive(:culture_for).and_return(stub_culture)
      Npc.create!(name: "Aex", subrole: "x", current_hp: 1, max_hp: 1, level: 1)
      name = described_class.unique_for(location: sub, rng: Random.new(0))
      expect(name).to match(/\AAex (II|III|IV|V|VI|VII)\z/)
    end

    it "uses Elara/Silas zero times across many rolls (we are escaping the trope pit)" do
      banned = %w[Elara Silas]
      200.times do
        name = described_class.for(location: sub, rng: Random.new(Random.new_seed))
        given = name.split(" ", 2).first
        expect(banned).not_to include(given), "rolled banned name=#{given.inspect} from culture pool"
      end
    end
  end

  describe ".assign_to_kingdoms!" do
    it "assigns a culture_id to every kingdom missing one" do
      bare = Faction.create!(name: "Bareland", subrole: "kingdom", is_kingdom: true, properties: {})
      described_class.assign_to_kingdoms!(rng: Random.new(0))
      bare.reload
      expect(bare.properties["culture_id"]).to be_a(String)
      expect(Harness::Naming::Library.find(bare.properties["culture_id"])).not_to be_nil
    end

    it "is idempotent — does not overwrite existing culture_id" do
      kingdom  # touches let to create
      described_class.assign_to_kingdoms!(rng: Random.new(0))
      expect(kingdom.reload.properties["culture_id"]).to eq("nord")
    end

    it "skips non-kingdom factions" do
      guild = Faction.create!(name: "Smiths", subrole: "guild", is_kingdom: false, properties: {})
      described_class.assign_to_kingdoms!(rng: Random.new(0))
      expect(guild.reload.properties["culture_id"]).to be_nil
    end
  end
end
