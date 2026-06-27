require "rails_helper"

RSpec.describe Harness::Tools::QueryEvents do
  let(:saltmere) { Location.create!(name: "Saltmere") }
  let(:elsewhere) { Location.create!(name: "Far Town") }
  let(:keeper)   { Npc.create!(name: "Bram", subrole: "keeper", location: saltmere) }
  let(:tool)     { described_class.new }

  def held_event_ids(holder)
    tool.call({ "for_holder_id" => holder.id }, nil)["events"].map { |e| e["id"] }
  end

  it "surfaces a local event at the holder's location even without participation (SHARE)" do
    ev = Event.create!(game_time: 100, scope: "local", location: saltmere,
                       details: { "narrative" => { "trigger" => "a courier arrived" } })
    expect(held_event_ids(keeper)).to include(ev.id)
  end

  it "does NOT surface a local event at a different location" do
    ev = Event.create!(game_time: 100, scope: "local", location: elsewhere,
                       details: { "narrative" => { "trigger" => "a fire" } })
    expect(held_event_ids(keeper)).not_to include(ev.id)
  end

  it "does NOT surface a personal event the holder did not participate in" do
    other = Npc.create!(name: "Tess", subrole: "smith", location: saltmere)
    ev = Event.create!(game_time: 100, scope: "personal", location: saltmere,
                       details: { "narrative" => { "trigger" => "a private word" } })
    EventParticipant.create!(event: ev, character: other, role: "actor")
    expect(held_event_ids(keeper)).not_to include(ev.id)
  end

  it "still surfaces regional+ public events regardless of location" do
    ev = Event.create!(game_time: 100, scope: "regional", location: elsewhere,
                       details: { "narrative" => { "trigger" => "a border skirmish" } })
    expect(held_event_ids(keeper)).to include(ev.id)
  end

  it "still surfaces events the holder directly participated in" do
    ev = Event.create!(game_time: 100, scope: "personal", location: elsewhere,
                       details: { "narrative" => { "trigger" => "a deal" } })
    EventParticipant.create!(event: ev, character: keeper, role: "actor")
    expect(held_event_ids(keeper)).to include(ev.id)
  end
end
