require "rails_helper"

RSpec.describe Harness::NarrativeShift::Realizer do
  let(:city)    { Location.create!(name: "Saltmere") }
  let(:tavern)  { Location.create!(name: "The Drowned Rat", parent: city) }
  let!(:player) { Player.create!(name: "Hero", location: tavern) }
  let(:speaker) { Npc.create!(name: "Vesna", subrole: "messenger", location: tavern) }
  let(:ctx)     { Harness::Turn::Context.new(player_location: tavern, game_time: 100, llm_grunt: StubLLM.new { "{}" }) }

  # Isolate the realizer's logic (naming / home / grounding) from the full
  # Hatchery materialize. The stub still creates a real row so the grounding
  # event has a subject to tag.
  before do
    allow(Harness::Character::Hatchery).to receive(:spawn) do |**kw|
      Npc.create!(name: kw[:name], subrole: kw[:subrole], location: kw[:location],
                  home_location_id: kw[:home_location_id], properties: kw[:properties] || {})
    end
  end

  def run(claim) = described_class.run(claim: claim, speaker: speaker, context: ctx)

  it "returns nil only when there is nothing to realize (no name and no gist)" do
    expect(run({})).to be_nil
    expect(run({ "name" => "   " })).to be_nil
    expect(Harness::Character::Hatchery).not_to have_received(:spawn)
  end

  it "spawns a role-referenced person, the name picker assigns a real name" do
    res = run({ "name" => "the surveyor", "subrole" => "surveyor", "gist" => "marked the foundations" })
    expect(res["minted"]).to be(true)
    minted = Npc.find(res["character_id"])
    expect(minted.name).not_to eq("the surveyor")        # picker named them
    expect(minted.name).to match(/\A[[:upper:]]/)         # a real name
    expect(minted.properties["role_reference"]).to eq("the surveyor")
  end

  it "keeps the spoken name verbatim when the NPC actually named them" do
    res = run({ "name" => "Harek", "subrole" => "contact", "gist" => "the relay contact" })
    expect(res["minted"]).to be(true)
    expect(Npc.find(res["character_id"]).name).to eq("Harek")
    expect(Harness::Character::Hatchery).to have_received(:spawn).with(hash_including(name: "Harek"))
  end

  it "links a spoken name to an existing character instead of duplicating" do
    existing = Npc.create!(name: "Harek", subrole: "contact", location: city)
    res = run({ "name" => "Harek", "subrole" => "contact" })
    expect(res).to include("linked" => true, "character_id" => existing.id)
    expect(Harness::Character::Hatchery).not_to have_received(:spawn)
  end

  it "homes a person at a named destination that resolves to a real Location (present, findable)" do
    relay = Location.create!(name: "Blackwood Relay")
    run({ "name" => "Harek", "at_location" => "blackwood relay" })
    expect(Harness::Character::Hatchery).to have_received(:spawn)
      .with(hash_including(location: relay, home_location_id: relay.id, dormant: false))
  end

  it "homes an unresolved person at the current location, dormant (no floating names)" do
    run({ "name" => "Harek", "gist" => "a cousin from nowhere named" })
    expect(Harness::Character::Hatchery).to have_received(:spawn)
      .with(hash_including(home_location_id: tavern.id, location: tavern, dormant: true))
  end

  it "parks a clean place name for later relocation, but not prose" do
    run({ "name" => "Harek", "at_location" => "Blackwood Relay" })
    run({ "name" => "Doran", "at_location" => "the highest pile of the first crossing point in the marsh" })
    expect(Npc.find_by(name: "Harek").properties["pending_location_name"]).to eq("Blackwood Relay")
    expect(Npc.find_by(name: "Doran").properties).not_to have_key("pending_location_name")
  end

  it "commits a shared grounding event that recalls the picked name from the role" do
    res = run({ "name" => "the surveyor", "subrole" => "surveyor", "gist" => "marked the marsh foundations" })
    ev = Event.last
    pids = ev.event_participants.pluck(:character_id)
    expect(pids).to include(speaker.id, player.id, res["character_id"])
    # "the surveyor is <Corin>" — so asking about the surveyor next turn recalls the name.
    expect(ev.details.dig("narrative", "trigger")).to match(/the surveyor is /)
  end
end
