require "rails_helper"

RSpec.describe Harness::Scene::StaffSeeder do
  let(:city) { Location.create!(name: "Saltmere", properties: { "kingdom" => "veles" }) }
  let(:tavern) do
    Location.create!(name: "the Alehouse", parent: city,
                     description: "A low-beamed taproom.",
                     properties: { "kind" => "sublocation", "manifest_key" => "tavern", "trade" => "barkeep" })
  end
  let(:llm) { StubLLM.new { |_p| { "personality" => "gruff, watchful, dry", "appearance" => "Broad-shouldered, with heavy hands and a bar-rag over one shoulder." }.to_json } }

  it "mechanically spawns the venue's keeper, homed at the venue" do
    npc = described_class.ensure!(tavern, llm: llm)
    expect(npc).to be_a(Npc)
    expect(npc.subrole).to eq("barkeep")
    expect(npc.home_location_id).to eq(tavern.id)
    expect(npc.location_id).to eq(tavern.id)
  end

  it "is idempotent — one keeper per venue" do
    described_class.ensure!(tavern, llm: llm)
    expect { described_class.ensure!(tavern, llm: llm) }.not_to change(Npc, :count)
  end

  it "seeds a successor when the keeper is dead" do
    first = described_class.ensure!(tavern, llm: llm)
    first.update!(max_hp: 10, current_hp: 0)
    expect { described_class.ensure!(tavern, llm: llm) }.to change(Npc, :count).by(1)
  end

  it "does nothing for non-manifest locations and top-level places" do
    plain = Location.create!(name: "the Back Room", parent: city)
    expect(described_class.ensure!(plain, llm: llm)).to be_nil
    expect(described_class.ensure!(city, llm: llm)).to be_nil
    expect(Npc.count).to eq(0)
  end

  describe ".name_all! (keepers named at layout, bodies at first meeting)" do
    let(:smithy) do
      Location.create!(name: "the Smithy", parent: city, properties: { "kind" => "sublocation", "manifest_key" => "smithy", "trade" => "smith" })
    end

    it "names a keeper for every trade room without one — a row with a name, trade and home, no body yet — and none for a plain room" do
      tavern; smithy
      Location.create!(name: "the Back Room", parent: city)
      named = described_class.name_all!(city, rng: Random.new(1))
      expect(named.map(&:subrole)).to match_array(%w[barkeep smith])
      smith = named.find { |n| n.subrole == "smith" }
      expect(smith.home_location_id).to eq(smithy.id)
      expect(smith.name).to match(/\A[[:upper:]]/)
      expect(smith.max_hp).to eq(0)
      expect(Harness::Scene::Residents.unmaterialized?(smith)).to be(true)
      expect(Harness::Scene::Residents.deceased?(smith)).to be(false)
    end

    it "adopts a trade-matching resident anchored at the root before naming a new one, and is idempotent" do
      smithy
      hengist = Npc.create!(name: "Hengist", subrole: "smith", location: city, home_location_id: city.id, current_hp: 5, max_hp: 5)
      expect(described_class.name_all!(city)).to eq([ hengist ])
      expect(hengist.reload.home_location_id).to eq(smithy.id)
      expect { described_class.name_all!(city) }.not_to change(Npc, :count)
    end

    it "counts a named keeper as staff: ensure! spawns no second one" do
      tavern
      described_class.name_all!(city)
      expect { described_class.ensure!(tavern, llm: llm) }.not_to change(Npc, :count)
    end
  end
end
