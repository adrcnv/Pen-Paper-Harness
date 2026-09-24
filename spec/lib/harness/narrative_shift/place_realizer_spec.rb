require "rails_helper"

RSpec.describe Harness::NarrativeShift::PlaceRealizer do
  let(:city)   { Location.create!(name: "Saltmere") }
  let(:tavern) { Location.create!(name: "The Drowned Rat", parent: city) }
  let(:ctx)    { Harness::Turn::Context.new(player_location: tavern, game_time: 100, llm_grunt: StubLLM.new { @answer || "{}" }) }

  def run(place) = described_class.run(place: place, context: ctx)

  it "links an existing place instead of duplicating it, article and case aside" do
    ctx # force tavern + city fixtures before measuring
    hall = Location.create!(name: "The Grand Hall", parent: city)
    expect {
      expect(run({ "name" => "grand hall" })).to include("linked" => true, "location_id" => hall.id)
    }.not_to change(Location, :count)
  end

  it "mints a scenery kind the bind judge names, under the town, and writes no event for it" do
    ctx
    @answer = %({"reasoning": "a lane behind the houses", "is": "scenery", "room_id": null, "scenery": "alley"})
    expect {
      res = run({ "name" => "the dirty alley", "about" => "where the cutpurses drink" })
      expect(res["minted"]).to be(true)
      expect(Location.find(res["location_id"]).parent).to eq(city)
    }.to change(Location, :count).by(1).and change(Event, :count).by(0)
  end

  it "refuses a place the town has not got — a spoken name stays a phrase, no room is coined" do
    ctx
    @answer = %({"reasoning": "no hall is listed", "is": "neither", "room_id": null, "scenery": null})
    expect {
      expect(run({ "name" => "The Grand Hall", "about" => "the town's meeting house" })).to be_nil
      expect(run({ "name" => "the mill" })).to be_nil
    }.not_to change(Location, :count)
  end

  it "ignores bad input" do
    expect(run(nil)).to be_nil
    expect(run({ "name" => "" })).to be_nil
  end
end
