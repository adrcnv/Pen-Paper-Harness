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
end
