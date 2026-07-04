require "rails_helper"

RSpec.describe Harness::NarrativeShift::PlaceRealizer do
  let(:city)   { Location.create!(name: "Saltmere") }
  let(:tavern) { Location.create!(name: "The Drowned Rat", parent: city) }
  let(:ctx)    { Harness::Turn::Context.new(player_location: tavern, game_time: 100, llm_grunt: StubLLM.new { "{}" }) }

  def run(place) = described_class.run(place: place, context: ctx)

  it "mints a proper-named place as a sublocation of the current town" do
    res = run({ "name" => "The Grand Hall", "about" => "the town's meeting house" })
    expect(res["minted"]).to be(true)
    loc = Location.find(res["location_id"])
    expect(loc.name).to eq("The Grand Hall")
    expect(loc.parent).to eq(city)         # root settlement, not the tavern the player is in
    expect(loc.description).to match(/meeting house/)
  end

  it "grounds the mint with an introduction event" do
    expect { run({ "name" => "Corin's Forge" }) }.to change(Event, :count).by(1)
    ev = Event.last
    expect(ev.details.dig("introduction", "target_name")).to eq("Corin's Forge")
  end

  it "links an existing place instead of duplicating it" do
    ctx # force tavern + city fixtures before measuring
    hall = Location.create!(name: "The Grand Hall", parent: city)
    expect {
      res = run({ "name" => "the grand hall" })
      expect(res).to include("linked" => true, "location_id" => hall.id)
    }.not_to change(Location, :count)
  end

  it "rejects a generic definite reference (the dupe guard)" do
    ctx # force tavern + city fixtures before measuring
    expect {
      expect(run({ "name" => "the mill" })).to be_nil
      expect(run({ "name" => "the market" })).to be_nil
    }.not_to change(Location, :count)
  end

  it "parents under a NAMED existing location when the speaker placed it there" do
    redmarsh = Location.create!(name: "Redmarsh")
    res = run({ "name" => "The Ferryman's Rest", "parent" => "redmarsh" })
    expect(Location.find(res["location_id"]).parent).to eq(redmarsh)
  end

  it "does not shadow a faction (kingdom/guild) name" do
    Faction.create!(name: "The Grand Hall")
    expect(run({ "name" => "The Grand Hall" })).to be_nil
  end
end
