require "rails_helper"

RSpec.describe Harness::Settlement::PlaceWriter do
  let(:town)   { Location.create!(name: "Saltmere") }
  let(:tavern) { Location.create!(name: "the Alehouse", parent: town, description: "A low-beamed taproom.") }
  let(:forge)  { Location.create!(name: "the Iron Anvil", parent: town, description: "A cramped smithy.") }
  let(:llm)    { StubLLM.new { @answer || "{}" } }
  let(:ctx)    { Harness::Turn::Context.new(player_location: tavern, game_time: 100, llm_grunt: llm) }

  def resolve(name, about: nil, source: :claim) = described_class.resolve(name: name, about: about, source: source, context: ctx)

  it "refuses a blank name without asking the judge" do
    expect(resolve("  ")).to be_refused
    expect(llm.user_calls).to be_empty
  end

  it "links the settlement's own room by name, article and case aside, without asking the judge" do
    forge
    res = resolve("Iron Anvil")
    expect(res).to be_linked
    expect(res.location).to eq(forge)
    expect(resolve("THE ALEHOUSE").location).to eq(tavern)
    expect(resolve("saltmere").location).to eq(town)
    expect(llm.user_calls).to be_empty
  end

  it "links another settlement by name, but never another town's room by a generic name" do
    far = Location.create!(name: "Coldleigh")
    Location.create!(name: "the Smithy", parent: far)
    tavern
    expect(resolve("coldleigh").location).to eq(far)
    expect(llm.user_calls).to be_empty
    expect(resolve("the Smithy")).to be_refused   # the stub judge answers {} — nothing local matched by name
    expect(llm.user_calls.size).to eq(1)
  end

  context "when the bind judge answers" do
    it "links a listed room, and shows the judge the rooms, the settlement and the scenery kinds" do
      forge
      @answer = %({"reasoning": "the forge is the smithy", "is": "listed_room", "room_id": #{forge.id}, "scenery": null})
      res = resolve("the forge just past the market", about: "where Corin works")
      expect(res).to be_linked
      expect(res.location).to eq(forge)
      payload = JSON.parse(llm.user_calls.last.sub(/\AINPUT:\n/, ""))
      expect(payload["rooms"].map { |r| r["id"] }).to contain_exactly(tavern.id, forge.id)
      expect(payload["settlement"]).to eq("id" => town.id, "name" => "Saltmere")
      expect(payload["scenery"].map { |s| s["key"] }).to eq(Harness::Settlement::Scenery.keys)
      expect(payload["spoken"]).to eq("name" => "the forge just past the market", "about" => "where Corin works")
      expect(llm.schema_calls.last).to eq(described_class::BIND_SCHEMA)
      expect(llm.sampling_calls.last).to include(temperature: 0, thinking: false)
    end

    it "links the settlement itself when the judge names it" do
      @answer = %({"reasoning": "in town", "is": "listed_room", "room_id": #{town.id}, "scenery": null})
      expect(resolve("somewhere in town").location).to eq(town)
    end

    it "mints a scenery kind once and links the second phrase for it to the same row" do
      @answer = %({"reasoning": "a lane behind the houses", "is": "scenery", "room_id": null, "scenery": "alley"})
      first = resolve("a dirty alley")
      expect(first).to be_minted
      expect(first.key).to eq("alley")
      expect(first.location.parent).to eq(town)
      second = resolve("the back lane")
      expect(second).to be_linked
      expect(second.location).to eq(first.location)
      expect(Location.where(parent_id: town.id).count).to eq(2)   # the tavern and the one alley
    end

    it "refuses what the settlement has not got, and mints nothing" do
      tavern
      @answer = %({"reasoning": "no smithy is listed", "is": "neither", "room_id": null, "scenery": null})
      expect { expect(resolve("Corin's Forge")).to be_refused }.not_to change(Location, :count)
    end

    it "refuses a room id the judge made up" do
      tavern
      @answer = %({"reasoning": "the hall", "is": "listed_room", "room_id": 999999, "scenery": null})
      expect(resolve("the Grand Hall")).to be_refused
    end

    it "refuses when the judge's answer is unreadable" do
      tavern
      @answer = "not json"
      expect(resolve("the Reeds")).to be_refused
    end
  end
end
