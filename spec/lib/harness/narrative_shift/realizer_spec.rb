require "rails_helper"

RSpec.describe Harness::NarrativeShift::Realizer do
  let(:city)    { Location.create!(name: "Saltmere") }
  let(:tavern)  { Location.create!(name: "The Drowned Rat", parent: city) }
  let!(:player) { Player.create!(name: "Hero", location: tavern) }
  let(:speaker) { Npc.create!(name: "Vesna", subrole: "messenger", location: tavern) }
  let(:ctx)     { Harness::Turn::Context.new(player_location: tavern, game_time: 100, llm_grunt: StubLLM.new { @answer || "{}" }) }

  # Isolate the realizer's logic (naming / home / grounding) from the full
  # Hatchery materialize. The stub still creates a real row so the grounding
  # event has a subject to tag.
  before do
    allow(Harness::Character::Hatchery).to receive(:spawn) do |**kw|
      Npc.create!(name: kw[:name], subrole: kw[:subrole], location: kw[:location],
                  home_location_id: kw[:home_location_id], properties: kw[:properties] || {}, current_hp: 5, max_hp: 5)
    end
  end

  def run(claim) = described_class.run(claim: claim, speaker: speaker, context: ctx)

  it "refuses a claim that names the player — never a namesake NPC" do
    speaker   # materialize the lazy fixture outside the count
    expect {
      expect(run({ "name" => "Hero", "subrole" => "traveller", "gist" => "saw the prints" })).to be_nil
    }.not_to change(Npc, :count)
  end

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

  describe "role-reference resolution (the two-Guard-Captains bug)" do
    it "an article-less role mention LINKS to the row a role-mint already realized (via stored role_reference)" do
      first = run({ "name" => "The Guard-Captain", "subrole" => "guard" })
      expect(first["minted"]).to be(true)
      mereth = Npc.find(first["character_id"])
      expect(mereth.properties["role_reference"]).to eq("The Guard-Captain")

      second = run({ "name" => "Guard-Captain", "subrole" => "authority", "gist" => "busy with a ledger dispute" })
      expect(second).to include("linked" => true, "character_id" => mereth.id)
      expect(Npc.where("LOWER(name) = ?", "guard-captain")).to be_empty
    end

    it "a repeated role-reference LINKS instead of minting a twin" do
      first  = run({ "name" => "the guard-captain", "subrole" => "guard" })
      second = run({ "name" => "The Guard-Captain", "subrole" => "guard" })
      expect(second).to include("linked" => true, "character_id" => first["character_id"])
    end

    it "a later role-reference resolves to a role-SHAPED literal name that slipped the proper-name gate" do
      first = run({ "name" => "Guard-Captain", "subrole" => "guard" }) # proper-shaped → literal name
      expect(Npc.find(first["character_id"]).name).to eq("Guard-Captain")

      second = run({ "name" => "the Guard-Captain", "subrole" => "guard" })
      expect(second).to include("linked" => true, "character_id" => first["character_id"])
    end
  end

  it "refuses a claim anchored at the player's CURRENT location — scenery, not a referral (the two-drovers bug)" do
    res = run({ "name" => "two drovers", "subrole" => "drover",
                "gist" => "arguing over a sprained ankle", "at_location" => "The Drowned Rat" })
    expect(res).to be_nil
    expect(Harness::Character::Hatchery).not_to have_received(:spawn)
  end

  it "homes a person at a named destination that resolves to a real Location (present, findable)" do
    relay = Location.create!(name: "Blackwood Relay")
    run({ "name" => "Harek", "at_location" => "blackwood relay" })
    expect(Harness::Character::Hatchery).to have_received(:spawn)
      .with(hash_including(location: relay, home_location_id: relay.id, dormant: false))
  end

  it "homes an unplaced person at the settlement root, awake — findable as any citizen, never dormant" do
    run({ "name" => "Harek", "gist" => "a cousin from nowhere named" })
    expect(Harness::Character::Hatchery).to have_received(:spawn)
      .with(hash_including(home_location_id: city.id, location: city, dormant: false))
  end

  it "homes the person at the existing room the bind judge names instead of minting a twin place" do
    tide_mill = Location.create!(name: "the Tide Mill", parent: city)
    @answer = %({"reasoning": "the mill is the Tide Mill", "is": "listed_room", "room_id": #{tide_mill.id}, "scenery": null})
    expect {
      run({ "name" => "Hrothgar", "subrole" => "ferryman", "at_location" => "the mill" })
    }.not_to change(Location, :count)
    expect(Harness::Character::Hatchery).to have_received(:spawn)
      .with(hash_including(location: tide_mill, home_location_id: tide_mill.id, dormant: false))
  end

  it "mints no room the town has not got — the anchor stays a phrase and the person is homed at the root" do
    @answer = %({"reasoning": "no mill is listed", "is": "neither", "room_id": null, "scenery": null})
    expect {
      run({ "name" => "Hrothgar", "subrole" => "ferryman", "at_location" => "the mill" })
    }.not_to change(Location, :count)
    expect(Harness::Character::Hatchery).to have_received(:spawn)
      .with(hash_including(location: city, home_location_id: city.id, dormant: false))
  end

  it "mints nothing for a prose anchor (person homed at the root, awake)" do
    expect {
      run({ "name" => "Doran", "at_location" => "the highest pile of the first crossing point in the marsh" })
    }.not_to change(Location, :count)
    expect(Harness::Character::Hatchery).to have_received(:spawn)
      .with(hash_including(location: city, dormant: false))
  end

  it "stamps the speaker into a named-claim ground event (referrals carry their source)" do
    run({ "name" => "Harek", "subrole" => "contact", "gist" => "the relay contact" })
    expect(Event.last.details.dig("narrative", "trigger")).to eq("Vesna named Harek to the player")
  end

  it "commits a shared grounding event that recalls the picked name from the role" do
    res = run({ "name" => "the surveyor", "subrole" => "surveyor", "gist" => "marked the marsh foundations" })
    ev = Event.last
    pids = ev.event_participants.pluck(:character_id)
    expect(pids).to include(speaker.id, player.id, res["character_id"])
    # "the surveyor is <Corin>" — so asking about the surveyor next turn recalls the name.
    expect(ev.details.dig("narrative", "trigger")).to match(/the surveyor is /)
  end

  describe "the office door (a claimed person's trade against the town's rows)" do
    let!(:smithy)  { Location.create!(name: "the Smithy", parent: city, properties: { "trade" => "smith" }) }
    let!(:hengist) { Npc.create!(name: "Hengist", subrole: "smith", location: smithy, home_location_id: smithy.id, current_hp: 5, max_hp: 5) }

    it "links a claim with a civic trade to the town's holder instead of minting a second one — by role or by name" do
      expect(run({ "name" => "the smith", "subrole" => "smith", "gist" => "could mend the blade" })).to include("linked" => true, "character_id" => hengist.id)
      expect(run({ "name" => "Varya the smith", "subrole" => "smith" })).to include("character_id" => hengist.id)
      expect(Harness::Character::Hatchery).not_to have_received(:spawn)
    end

    it "seeds the civic room's keeper for a claim the player has not yet met — never a row named 'Saltmere's reeve'" do
      hall = Location.create!(name: "the Moot Hall", parent: city, properties: { "trade" => "reeve" })
      res  = run({ "name" => "Saltmere's reeve", "subrole" => "reeve", "at_location" => "the Moot Hall" })
      expect(res["linked"]).to be(true)
      keeper = Npc.find(res["character_id"])
      expect(keeper.home_location_id).to eq(hall.id)
      expect(keeper.subrole).to eq("reeve")
      expect(Npc.where(name: "Saltmere's reeve")).to be_empty
      speaker   # materialize the lazy fixture outside the count
      expect { expect(run({ "name" => "Borin", "subrole" => "reeve", "gist" => "keeps to the hall" })["character_id"]).to eq(keeper.id) }.not_to change(Npc, :count)
    end

    it "links the keeper of the room a claim anchors to, for a crew's trade as well — 'the salter out at the Flats'" do
      flats = Location.create!(name: "the Flats", parent: city, properties: { "trade" => "salter" })
      res = run({ "name" => "the salter out at the Flats", "subrole" => "salter", "at_location" => "the Flats" })
      expect(res["linked"]).to be(true)
      expect(Npc.find(res["character_id"]).home_location_id).to eq(flats.id)
      expect(run({ "name" => "the salter", "subrole" => "salter" })["minted"]).to be(true)   # unanchored, a plural trade: a person of their own
    end

    it "refuses a claimed holder of a civic office the town lacks, and still mints a named guard (a crew) or a named stranger" do
      expect(run({ "name" => "the reeve", "subrole" => "reeve", "gist" => "would hear the case" })).to be_nil
      expect(run({ "name" => "Osric", "subrole" => "reeve" })).to be_nil
      expect(Npc.where(name: "Osric")).to be_empty
      expect(run({ "name" => "Wulf", "subrole" => "guard" })["minted"]).to be(true)
      expect(run({ "name" => "Harek Smith", "subrole" => "contact" })["minted"]).to be(true)
    end

    it "leaves a claim anchored in another town to the Realizer as before" do
      far = Location.create!(name: "Coldleigh")
      res = run({ "name" => "the reeve", "subrole" => "reeve", "at_location" => "Coldleigh" })
      expect(res["minted"]).to be(true)
      expect(Harness::Character::Hatchery).to have_received(:spawn).with(hash_including(home_location_id: far.id))
    end
  end
end
