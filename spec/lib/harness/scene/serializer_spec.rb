require "rails_helper"

RSpec.describe Harness::Scene::Serializer do
  let(:city)   { Location.create!(name: "Saltmere") }
  let(:tavern) { Location.create!(name: "Tavern", parent: city) }
  let!(:maren) { Npc.create!(name: "Maren", subrole: "barkeep", location: tavern) }

  def build_active
    Harness::Scene::Active.new(
      location:             tavern,
      snapshot:             Harness::Scene::Assembler.for(location: tavern),
      narrations:           [ { "input" => "hello", "narration" => "The room is dim." } ],
      internal_state:       { maren.id => "wipes the bar" },
      agendas:              { maren.id => "wants the tab settled" },
      extras:               [ "a dozing dog" ],
      entered_at_game_time: 100,
      spoken_ids:           [ maren.id ],
      last_lines:           { maren.id => "What'll it be?" },
      contest_ledger:       { "#{maren.id}:social" => { "kind" => "persuasion", "result" => "failure" } },
      dispositions:         { maren.id => "guarded" }
    )
  end

  it "round-trips through JSON storage with integer character-id keys intact" do
    stored   = JSON.parse(JSON.generate(described_class.dump(build_active)))
    restored = described_class.load(stored)

    expect(restored.location).to eq(tavern)
    expect(restored.narrations).to eq([ { "input" => "hello", "narration" => "The room is dim." } ])
    expect(restored.state_for(maren.id)).to eq("wipes the bar")     # int-keyed lookup
    expect(restored.agenda_for(maren.id)).to eq("wants the tab settled")
    expect(restored.spoken?(maren.id)).to be(true)
    expect(restored.last_line_for(maren.id)).to eq("What'll it be?")
    expect(restored.present_extras).to eq([ "a dozing dog" ])
    expect(restored.entered_at_game_time).to eq(100)
    expect(restored.contest_for("#{maren.id}:social")).to eq({ "kind" => "persuasion", "result" => "failure" })
    expect(restored.disposition_for(maren.id)).to eq("guarded")
  end

  it "rebuilds the snapshot from the DB on load (pure read — no draws)" do
    restored = described_class.load(JSON.parse(JSON.generate(described_class.dump(build_active))))
    expect(restored.present_characters.map(&:id)).to eq([ maren.id ])
  end

  it "load returns nil when the location no longer exists (stale row)" do
    stored = described_class.dump(build_active)
    stored["location_id"] = 99_999
    expect(described_class.load(stored)).to be_nil
  end

  it "dump returns nil for a nil scene (between scenes)" do
    expect(described_class.dump(nil)).to be_nil
  end
end
