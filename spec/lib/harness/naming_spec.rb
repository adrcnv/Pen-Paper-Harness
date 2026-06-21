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

  describe ".place_for" do
    let(:nord) { Harness::Naming::Library.find("nord") }

    it "compounds a prefix with a suffix or a space-word from the culture pools" do
      100.times do
        name = described_class.place_for(culture: nord, rng: Random.new(Random.new_seed))
        expect(name).to be_present
        if name.include?(" ")
          pre, word = name.split(" ", 2)
          expect(nord["place_prefix"]).to include(pre)
          expect(nord["place_word"]).to include(word)
        else
          # prefix + suffix joined: some prefix must be a leading substring and
          # the remainder a known suffix.
          ok = nord["place_prefix"].any? do |pre|
            name.start_with?(pre) && nord["place_suffix"].include?(name[pre.length..])
          end
          expect(ok).to be(true), "#{name.inspect} not a prefix+suffix compound"
        end
      end
    end

    it "is stable with a fixed rng" do
      a = described_class.place_for(culture: nord, rng: Random.new(7))
      b = described_class.place_for(culture: nord, rng: Random.new(7))
      expect(a).to eq(b)
    end
  end

  describe ".kingdom_name_for" do
    let(:nord) { Harness::Naming::Library.find("nord") }

    it "always ends in a kingdom_suffix from the culture" do
      50.times do
        name = described_class.kingdom_name_for(culture: nord, rng: Random.new(Random.new_seed))
        expect(nord["kingdom_suffix"]).to include(name.split(" ").last)
      end
    end
  end

  describe ".unique_place_for / .unique_kingdom_name_for" do
    let(:nord) { Harness::Naming::Library.find("nord") }

    it "never collides with an existing Location, Faction, or an in-memory taken set" do
      taken = described_class.taken_set
      names = []
      40.times do
        n = described_class.unique_place_for(culture: nord, taken: taken, rng: Random.new(Random.new_seed))
        names << n
      end
      # All globally distinct (case-insensitive) and none pre-existing.
      expect(names.map(&:downcase).uniq.size).to eq(names.size)
      names.each { |n| expect(Location.exists?(name: n)).to be(false) }
    end

    it "avoids a name already held by a Faction (city can't equal a kingdom)" do
      Faction.create!(name: "Frostfell", subrole: "kingdom", is_kingdom: true)
      # Stub a 1-combo culture that would ONLY ever produce "Frostfell" so the
      # collision path must engage the disambiguator.
      tiny = { "id" => "tiny", "place_prefix" => [ "Frost" ], "place_suffix" => [ "fell" ],
               "place_word" => [], "kingdom_suffix" => [ "Reach" ] }
      name = described_class.unique_place_for(culture: tiny, rng: Random.new(0))
      expect(name).not_to eq("Frostfell")
      expect(name).to match(/Frostfell/) # disambiguated form, e.g. "North Frostfell"
    end

    it "seeds taken_set from both Locations and Factions" do
      Location.create!(name: "Ironby", parent: nil)
      Faction.create!(name: "The Storm Jarldom", subrole: "kingdom", is_kingdom: true)
      set = described_class.taken_set
      expect(set).to include("ironby")
      expect(set).to include("the storm jarldom")
    end
  end

  describe ".gender_for" do
    it "resolves a male pool name to male" do
      expect(described_class.gender_for("Bjorn")).to eq("male")
      expect(described_class.gender_for("Garrick")).to eq("male")
    end

    it "resolves a female pool name to female" do
      expect(described_class.gender_for("Astrid")).to eq("female")
      expect(described_class.gender_for("Sasha")).to eq("female") # the reported case
    end

    it "ignores the family name (checks the first token only)" do
      expect(described_class.gender_for("Astrid Stenholm")).to eq("female")
    end

    it "returns nil for a name in no pool (LLM-invented)" do
      expect(described_class.gender_for("Zxqwflorn")).to be_nil
      expect(described_class.gender_for("")).to be_nil
    end
  end

  describe ".for gender grounding" do
    it "always draws a name whose gender is recoverable via gender_for" do
      # Every mechanically-drawn name must round-trip: the pool it came from
      # is exactly what gender_for reports. This is the invariant Hatchery
      # leans on to ground properties.gender without threading gender through.
      50.times do
        name   = described_class.for(location: sub, rng: Random.new(Random.new_seed))
        first  = name.split(" ", 2).first
        expect(described_class.gender_for(first)).to be_in(%w[male female]),
          "drawn name #{first.inspect} is in neither gendered pool"
      end
    end

    it "draws from both gendered pools across many rolls" do
      nord = Harness::Naming::Library.find("nord")
      genders = 100.times.map do
        described_class.gender_for(described_class.for(location: sub, rng: Random.new(Random.new_seed)).split(" ").first)
      end
      expect(genders).to include("male")
      expect(genders).to include("female")
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
