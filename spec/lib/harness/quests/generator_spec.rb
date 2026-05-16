require "rails_helper"

RSpec.describe Harness::Quests::Generator do
  let(:kingdom) { Faction.create!(name: "Karhast", subrole: "kingdom", is_kingdom: true, properties: { "culture_id" => "nord" }) }
  let(:city) do
    Location.create!(
      name:       "Helmrest",
      parent:     nil,
      x:          0.0,
      y:          0.0,
      biome:      "lowland",
      faction:    kingdom,
      properties: { "tags" => %w[port mercantile], "quest_debt" => 2, "quest_generated_count" => 0 }
    )
  end

  let(:current_game_time) { 100_000 }

  # Mechanical-naming era: characters[] has NO name field. Engine assigns.
  let(:author_payload) do
    {
      "name"                              => "Recover Helmrest's shipment",
      "summary"                            => "The grain shipment was waylaid; the player recovers it.",
      "kickoff_narrative"                  => "The merchant vented at the warehouse — the courier never came back.",
      "kickoff_game_time_offset_minutes"   => 4200,
      "kickoff_participant_slots"          => [ "giver", "supporters[0]", "supporters[1]", "antagonist" ],
      "characters" => [
        { "slot" => "giver",       "subrole" => "merchant",      "placement" => "giver_sublocation" },
        { "slot" => "supporters",  "subrole" => "dockhand",      "placement" => "city" },
        { "slot" => "supporters",  "subrole" => "barkeep",       "placement" => "city" },
        { "slot" => "antagonist",  "subrole" => "bandit_leader", "placement" => "antagonist_sublocation" }
      ],
      "reused_characters" => [],
      "locations" => [
        { "slot" => "giver_sublocation",      "name" => "Stormcrag Warehouse", "description" => "A wooden warehouse along the docks." },
        { "slot" => "antagonist_sublocation", "name" => "The Salt Quarry",     "description" => "An abandoned quarry above the coast." }
      ],
      "items" => [
        { "slot" => "cargo", "subrole" => "document", "anchored_at" => "antagonist_sublocation" }
      ],
      "steps" => [
        { "description" => "Speak with the dockhand about the caravan's route" },
        { "description" => "Press the barkeep for who paid them off" },
        { "description" => "Track the bandit captain to the Salt Quarry" },
        { "description" => "Recover the cargo" }
      ]
    }
  end

  let(:llm) { StubLLM.new { |_combined| author_payload.to_json } }

  before do
    allow(Harness::Quests::ArchetypePicker).to receive(:pick).and_return(Harness::Quests::Library.find("missing_courier"))
  end

  it "commits the full quest in one pass" do
    expect(Quest.count).to eq(0)
    described_class.new(llm_client: llm, logger: Logger.new(nil), rng: Random.new(0))
      .generate(city: city, current_game_time: current_game_time)

    expect(Quest.count).to eq(1)
    quest = Quest.first
    expect(quest.name).to eq("Recover Helmrest's shipment")
    expect(quest.state).to eq("offered")
    expect(quest.archetype_id).to eq("missing_courier")
    expect(quest.city.id).to eq(city.id)
    expect(quest.quest_steps.count).to eq(4)
    expect(quest.quest_steps.order(:position).map(&:fulfillment_kind)).to eq(
      %w[information information character_at_location item_in_inventory]
    )
  end

  it "assigns mechanical names from the kingdom's culture (no Marcus / Elara)" do
    described_class.new(llm_client: llm, rng: Random.new(0)).generate(city: city, current_game_time: current_game_time)

    # The four fresh spawns all draw from the 'nord' culture pool.
    nord = Harness::Naming::Library.find("nord")
    fresh_names = Character.where.not(name: nil).pluck(:name)
    expect(fresh_names.size).to be >= 4
    fresh_names.each do |full|
      given = full.split(" ", 2).first
      expect(nord["given"]).to include(given), "given=#{given.inspect} not in nord pool — drew from wrong culture or invented a name"
    end
  end

  it "places each fresh character at the right sublocation" do
    described_class.new(llm_client: llm, rng: Random.new(0)).generate(city: city, current_game_time: current_game_time)
    quest = Quest.first

    expect(quest.giver.location.name).to eq("Stormcrag Warehouse")
    antagonist_loc = Location.find_by(name: "The Salt Quarry")
    antagonist = Character.where(location_id: antagonist_loc.id).first
    expect(antagonist).not_to be_nil
    expect(antagonist.properties["quest_slot"]).to eq("antagonist")
  end

  it "creates two fresh sublocations as children of the city" do
    described_class.new(llm_client: llm, rng: Random.new(0)).generate(city: city, current_game_time: current_game_time)
    subs = Location.where(parent_id: city.id).pluck(:name).sort
    expect(subs).to eq([ "Stormcrag Warehouse", "The Salt Quarry" ])
  end

  it "commits the backward kickoff event tagging the four slot fills" do
    described_class.new(llm_client: llm, rng: Random.new(0)).generate(city: city, current_game_time: current_game_time)

    quest = Quest.first
    ev = Event.find(quest.created_event_id)
    expect(ev.game_time).to eq(current_game_time - 4200)
    expect(ev.location.name).to eq("Stormcrag Warehouse")
    expect(ev.event_participants.count).to eq(4)
  end

  it "bumps the city's quest_generated_count after a successful commit" do
    described_class.new(llm_client: llm, rng: Random.new(0)).generate(city: city, current_game_time: current_game_time)
    city.reload
    expect(city.properties["quest_generated_count"]).to eq(1)
  end

  it "returns nil when archetype picker finds nothing eligible" do
    allow(Harness::Quests::ArchetypePicker).to receive(:pick)
      .and_raise(Harness::Quests::ArchetypePicker::NoArchetypeError, "no archetype")

    result = described_class.new(llm_client: llm).generate(city: city, current_game_time: current_game_time)
    expect(result).to be_nil
    expect(Quest.count).to eq(0)
  end

  it "returns nil and does not commit when the LLM output is malformed past retry budget" do
    bad_llm = StubLLM.new { |_| "{not json" }
    result = described_class.new(llm_client: bad_llm, max_retries: 0).generate(city: city, current_game_time: current_game_time)
    expect(result).to be_nil
    expect(Quest.count).to eq(0)
    expect(Character.count).to eq(0)
  end

  describe "kickoff floor clamp (safety net)" do
    let!(:existing_supporter) do
      Npc.create!(
        name: "Korr",
        subrole: "barkeep",
        location_id: city.id,
        current_hp: 1, max_hp: 1, level: 1, character_class: "commoner"
      )
    end

    # Korr has a real narrative event at game_time = 99_500.
    let!(:korrs_event) do
      e = Event.create!(game_time: 99_500, scope: "local", location: city, details: { "narrative" => "Korr did a thing" })
      EventParticipant.create!(event: e, character: existing_supporter, role: "actor")
      e
    end

    let(:clamp_payload) do
      p = author_payload.deep_dup
      sup_idx = p["characters"].index { |c| c["slot"] == "supporters" }
      p["characters"].delete_at(sup_idx)
      p["reused_characters"] = [ { "slot" => "supporters", "existing_character_id" => existing_supporter.id } ]
      p["kickoff_game_time_offset_minutes"] = 1500  # kickoff = 98_500, BEFORE floor 99_500
      p["kickoff_participant_slots"] = [ "giver", "supporters[0]", "supporters[1]", "antagonist" ]
      p
    end

    # If the LLM somehow sneaks past the hydrator (e.g., race conditions, or
    # the LLM author cluster is technically a valid reuse but the committer
    # finds events the hydrator missed), the clamp picks up the slack and
    # commits with an adjusted kickoff instead of crashing.
    it "clamps kickoff to floor+1 when the committer detects a violation the hydrator missed" do
      # Hydrator would normally reject this. Stub the local_cast lookup to
      # hide the floor from the hydrator so the committer clamp fires.
      llm = StubLLM.new { |_| clamp_payload.to_json }
      generator = described_class.new(llm_client: llm, rng: Random.new(0))
      # Force the generator to surface the reused character WITHOUT its floor.
      allow(generator).to receive(:local_cast_for).and_return(
        [ { "id" => existing_supporter.id, "name" => existing_supporter.name, "subrole" => existing_supporter.subrole, "earliest_event_game_time" => nil } ]
      )

      generator.generate(city: city, current_game_time: current_game_time)

      quest = Quest.first
      expect(quest).not_to be_nil
      kickoff_ev = Event.find(quest.created_event_id)
      # Clamp pushes kickoff to korr's floor + 1 = 99_501.
      expect(kickoff_ev.game_time).to eq(99_501)
    end
  end

  describe "reuse path" do
    let!(:existing_supporter) do
      Npc.create!(
        name: "Old Silas Holdwick",
        subrole: "barkeep",
        location_id: city.id,
        current_hp: 1, max_hp: 1, level: 1, character_class: "commoner"
      )
    end

    let(:reuse_payload) do
      p = author_payload.deep_dup
      # Drop one fresh supporter; reuse Silas instead.
      sup_idx = p["characters"].index { |c| c["slot"] == "supporters" }
      p["characters"].delete_at(sup_idx)
      p["reused_characters"] = [
        { "slot" => "supporters", "existing_character_id" => existing_supporter.id }
      ]
      # supporters[0] = remaining fresh; supporters[1] = reused Silas.
      p["kickoff_participant_slots"] = [ "giver", "supporters[0]", "supporters[1]", "antagonist" ]
      p
    end

    let(:reuse_llm) { StubLLM.new { |_| reuse_payload.to_json } }

    it "spawns 3 fresh and reuses the named existing character (no new row for Silas)" do
      pre_chars = Character.count
      described_class.new(llm_client: reuse_llm, rng: Random.new(0)).generate(city: city, current_game_time: current_game_time)
      post_chars = Character.count
      # 3 fresh spawns added; existing Silas not duplicated.
      expect(post_chars - pre_chars).to eq(3)
      expect(Character.where(name: "Old Silas Holdwick").count).to eq(1)
    end

    it "tags the reused character in the kickoff event" do
      described_class.new(llm_client: reuse_llm, rng: Random.new(0)).generate(city: city, current_game_time: current_game_time)
      ev = Event.find(Quest.first.created_event_id)
      participant_ids = ev.event_participants.map(&:character_id)
      expect(participant_ids).to include(existing_supporter.id)
    end
  end
end
