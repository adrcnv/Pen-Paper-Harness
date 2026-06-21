require "rails_helper"

RSpec.describe Harness::Worldgen::FromDb do
  describe ".load round-tripping a generated + persisted world" do
    before do
      map = Harness::Worldgen::Generator.generate(seed: 31337, size: 100, city_count: 10, kingdom_count: 3)
      # name cities/kingdoms minimally so persistence has non-nil names
      map.cities.each   { |c| c.name = "City#{c.id}" }
      map.kingdoms.each { |k| k.name = "Kingdom#{k.id}" }
      Harness::Worldgen::Persister.persist!(map: map)
      @generated = map
    end

    it "restores geography (seed + rivers) from the worlds row" do
      reloaded = described_class.load
      expect(reloaded.seed).to eq("31337")  # stored as string (seeds can be 128-bit)
      expect(reloaded.geography).to be_a(Harness::Worldgen::Geography)
      expect(reloaded.geography.rivers.map(&:points))
        .to eq(@generated.geography.rivers.map(&:points))
    end

    it "restores terrain + coastal/riverside facts onto each city" do
      reloaded = described_class.load
      reloaded.cities.each do |c|
        expect(Harness::Worldgen::Terrain::LAND.map(&:to_s)).to include(c.terrain)
        expect([ true, false ]).to include(c.coastal)
        expect([ true, false ]).to include(c.riverside)
      end
    end

    it "restores the settlement profile (basis/size/wealth) onto each city" do
      reloaded = described_class.load
      reloaded.cities.each do |c|
        expect(Harness::Settlement::Profile::BASES).to include(c.economic_basis)
        expect(Harness::Settlement::Profile::SIZES).to include(c.size)
        expect(Harness::Settlement::Profile::WEALTH_TIERS).to include(c.wealth)
      end
    end

    it "matches the generated cities' terrain facts after the round-trip" do
      reloaded = described_class.load
      gen_by_name = @generated.cities.index_by(&:name)
      reloaded.cities.each do |c|
        src = gen_by_name[c.name]
        expect(c.terrain).to eq(src.terrain)
        expect(c.coastal).to eq(src.coastal)
        expect(c.riverside).to eq(src.riverside)
      end
    end
  end

  describe ".load with no worlds row (pre-geography save)" do
    it "falls back to geography: nil / seed: nil" do
      ::Faction.create!(name: "K", subrole: "kingdom", is_kingdom: true)
      ::Location.create!(name: "C", x: 10.0, y: 10.0, biome: "lowland",
                         faction_id: ::Faction.first.id)
      reloaded = described_class.load
      expect(reloaded.seed).to be_nil
      expect(reloaded.geography).to be_nil
      expect(reloaded.cities.size).to eq(1)
    end
  end
end
