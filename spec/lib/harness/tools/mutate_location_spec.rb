require "rails_helper"

RSpec.describe Harness::Tools::MutateLocation do
  let(:tool)    { described_class.new }
  let(:loc)     { Location.create!(name: "Keep Gate") }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 100) }

  it "appends an alteration to location.properties and persists" do
    res = tool.call({ "location_id" => loc.id, "alteration" => "the north door is barricaded" }, context)
    expect(res["alteration"]).to eq("the north door is barricaded")
    expect(loc.reload.properties["alterations"]).to eq([ "the north door is barricaded" ])
  end

  it "accumulates multiple alterations in order" do
    tool.call({ "location_id" => loc.id, "alteration" => "door barred" }, context)
    tool.call({ "location_id" => loc.id, "alteration" => "window smashed" }, context)
    expect(loc.reload.properties["alterations"]).to eq([ "door barred", "window smashed" ])
  end

  it "logs a local-scope event" do
    expect {
      tool.call({ "location_id" => loc.id, "alteration" => "fire set in the hall" }, context)
    }.to change { Event.where(location_id: loc.id).count }.by(1)
  end

  it "does NOT set scene_dirty (persists for next assembly, no rebuild)" do
    tool.call({ "location_id" => loc.id, "alteration" => "wall breached" }, context)
    expect(context.scene_dirty).to be(false)
  end

  it "errors on an unknown location" do
    expect(tool.call({ "location_id" => 9999, "alteration" => "x" }, context)).to have_key("error")
  end

  it "errors on a blank alteration" do
    expect(tool.call({ "location_id" => loc.id, "alteration" => "   " }, context)).to have_key("error")
  end
end
