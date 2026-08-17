require "rails_helper"

RSpec.describe Harness::Scene::Whereabouts do
  # Mirehold = a city; Tavern (open day/evening/night) + Smithy (trade:
  # morning/day) are venue sublocations. Lair = a wilderness site.
  let(:mirehold) { Location.create!(name: "Mirehold", x: 0.0, y: 0.0) }
  let(:tavern)   { Location.create!(name: "Tavern", parent_id: mirehold.id, properties: { "kind" => "sublocation" }) }
  let(:smithy)   { Location.create!(name: "Smithy", parent_id: mirehold.id, properties: { "kind" => "sublocation" }) }
  let(:lair)     { Location.create!(name: "Bend", properties: { "kind" => "wilderness_leaf", "encounter_type" => "combat" }) }

  WB_MORNING = 8 * 60
  WB_NOON    = 12 * 60
  WB_EVENING = 19 * 60
  WB_NIGHT   = 23 * 60

  def npc(attrs = {})
    @n ||= 0; @n += 1
    Npc.create!({ name: "NPC#{@n}", subrole: "merchant", current_hp: 5, max_hp: 5 }.merge(attrs))
  end

  before do
    # Hold the street roll open so placement-logic tests are deterministic;
    # the roll itself is covered in its own describe below.
    allow(described_class).to receive(:at_large?).and_return(true)
  end

  describe ".resolve" do
    it "puts a follower wherever the player is, above everything" do
      player = Player.create!(name: "Hero", location_id: tavern.id)
      pal    = npc(location_id: mirehold.id, home_location_id: mirehold.id,
                   properties: { "following_player" => true })
      expect(described_class.resolve(pal, WB_NOON)).to eq(tavern.id)
      expect(player.location_id).to eq(tavern.id)
    end

    it "puts a due meet's counterparty at the meeting place, even over their post" do
      player = Player.create!(name: "Hero", location_id: mirehold.id)
      keeper = npc(subrole: "smith", location_id: smithy.id, home_location_id: smithy.id)
      Obligation.create!(kind: "meet", status: "open", debtor: keeper, creditor: player,
                         terms: "meet at the tavern", due_time: WB_NOON + 30, location_id: tavern.id)
      expect(described_class.resolve(keeper, WB_NOON)).to eq(tavern.id)
    end

    it "ignores a meet outside its due window" do
      player = Player.create!(name: "Hero", location_id: mirehold.id)
      keeper = npc(subrole: "smith", location_id: smithy.id, home_location_id: smithy.id)
      Obligation.create!(kind: "meet", status: "open", debtor: keeper, creditor: player,
                         terms: "meet tomorrow", due_time: WB_NOON + 2000, location_id: tavern.id)
      expect(described_class.resolve(keeper, WB_NOON)).to eq(smithy.id)
    end

    it "puts a venue-anchored keeper at their post while it is open" do
      keeper = npc(subrole: "smith", location_id: mirehold.id, home_location_id: smithy.id)
      expect(described_class.resolve(keeper, WB_NOON)).to eq(smithy.id)
    end

    it "sends an off-shift keeper out to the settlement root" do
      keeper = npc(subrole: "smith", location_id: smithy.id, home_location_id: smithy.id)
      expect(described_class.resolve(keeper, WB_EVENING)).to eq(mirehold.id)
    end

    it "resolves a sleeping settlement NPC nowhere (abstract housing)" do
      citizen = npc(location_id: mirehold.id, home_location_id: mirehold.id)
      expect(described_class.resolve(citizen, WB_NIGHT)).to be_nil
    end

    it "keeps a lair dweller at the lair even at night (literal housing)" do
      bandit = npc(subrole: "bandit", location_id: lair.id, home_location_id: lair.id)
      expect(described_class.resolve(bandit, WB_NIGHT)).to eq(lair.id)
    end

    it "keeps a tavern keeper behind the bar at night and sleeping of a morning" do
      alehouse = Location.create!(name: "the Alehouse", parent_id: mirehold.id)
      keeper   = npc(subrole: "barkeep", location_id: alehouse.id, home_location_id: alehouse.id)
      expect(described_class.resolve(keeper, WB_NIGHT)).to eq(alehouse.id)
      expect(described_class.resolve(keeper, WB_MORNING)).to be_nil
    end

    it "honors a live pin for a free NPC" do
      patron = npc(subrole: "minstrel", location_id: mirehold.id, home_location_id: mirehold.id)
      described_class.pin!(patron, tavern, WB_EVENING)
      expect(described_class.resolve(patron.reload, WB_EVENING + 30)).to eq(tavern.id)
    end

    it "ignores an expired pin" do
      patron = npc(subrole: "minstrel", location_id: mirehold.id, home_location_id: mirehold.id,
                   properties: { "pin" => { "location_id" => tavern.id, "until" => WB_NOON - 1 } })
      expect(described_class.resolve(patron, WB_NOON)).to eq(mirehold.id)
    end

    it "lets the work block outrank a pin — the morning drinker leaves for the forge" do
      smith = npc(subrole: "smith", location_id: tavern.id, home_location_id: smithy.id,
                  properties: { "pin" => { "location_id" => tavern.id, "until" => WB_NOON + 60 } })
      expect(described_class.resolve(smith, WB_NOON)).to eq(smithy.id)
    end

    it "resolves a transient (nil anchor) nowhere" do
      stray = npc(location_id: tavern.id, home_location_id: nil)
      expect(described_class.resolve(stray, WB_NOON)).to be_nil
    end

    it "returns the cache verbatim with no game_time (clockless = cache is truth)" do
      keeper = npc(subrole: "smith", location_id: tavern.id, home_location_id: smithy.id)
      expect(described_class.resolve(keeper, nil)).to eq(tavern.id)
    end
  end

  describe ".at_large? (the street roll)" do
    it "hides a free resident whose roll fails — functionally, they are at home" do
      citizen = npc(subrole: "minstrel", location_id: mirehold.id, home_location_id: mirehold.id)
      allow(described_class).to receive(:at_large?).and_return(false)
      expect(described_class.resolve(citizen, WB_NOON)).to be_nil
    end

    it "is stable within a phase and splits the population" do
      allow(described_class).to receive(:at_large?).and_call_original
      citizen = npc(location_id: mirehold.id, home_location_id: mirehold.id)
      expect(described_class.at_large?(citizen, WB_NOON))
        .to eq(described_class.at_large?(citizen, WB_NOON + 45))
      fake = Struct.new(:id)
      rolls = (1..200).map { |i| described_class.at_large?(fake.new(i), WB_NOON) }
      expect(rolls.uniq).to contain_exactly(true, false) # some out, some home
    end
  end

  describe ".present_at" do
    it "has free residents standing at the settlement root" do
      citizen = npc(subrole: "minstrel", location_id: mirehold.id, home_location_id: mirehold.id)
      expect(described_class.present_at(mirehold, WB_NOON)).to include(citizen)
    end

    it "pulls a keeper to their open post even when cached elsewhere" do
      keeper = npc(subrole: "smith", location_id: mirehold.id, home_location_id: smithy.id)
      expect(described_class.present_at(smithy, WB_NOON)).to include(keeper)
      expect(described_class.present_at(mirehold, WB_NOON)).not_to include(keeper)
    end

    it "keeps a transient prop where it was cached" do
      stray = npc(location_id: tavern.id, home_location_id: nil)
      expect(described_class.present_at(tavern, WB_EVENING)).to include(stray)
    end

    it "does not show a pinned resident at the root they are anchored to" do
      patron = npc(subrole: "minstrel", location_id: mirehold.id, home_location_id: mirehold.id)
      described_class.pin!(patron, tavern, WB_EVENING)
      expect(described_class.present_at(mirehold, WB_EVENING)).not_to include(patron.reload)
      expect(described_class.present_at(tavern, WB_EVENING)).to include(patron)
    end

    it "excludes corpses and dormant rows" do
      corpse  = npc(location_id: mirehold.id, home_location_id: mirehold.id, current_hp: 0)
      dormant = npc(location_id: mirehold.id, home_location_id: mirehold.id, properties: { "dormant" => true })
      present = described_class.present_at(mirehold, WB_NOON)
      expect(present).not_to include(corpse, dormant)
    end

    it "reads the cache with no game_time" do
      here = npc(location_id: tavern.id, home_location_id: mirehold.id)
      expect(described_class.present_at(tavern, nil)).to include(here)
    end
  end

  describe ".refresh!" do
    it "writes the cache for everyone pulled in" do
      keeper = npc(subrole: "smith", location_id: mirehold.id, home_location_id: smithy.id)
      present = described_class.refresh!(smithy, WB_NOON)
      expect(present).to include(keeper)
      expect(keeper.reload.location_id).to eq(smithy.id)
    end

    it "sweeps out a cached row that resolves elsewhere — the smith goes to work" do
      keeper = npc(subrole: "smith", location_id: mirehold.id, home_location_id: smithy.id)
      present = described_class.refresh!(mirehold, WB_NOON)
      expect(present).not_to include(keeper)
      expect(keeper.reload.location_id).to eq(smithy.id)
    end

    it "clears an expired pin in passing" do
      patron = npc(subrole: "minstrel", location_id: tavern.id, home_location_id: mirehold.id,
                   properties: { "pin" => { "location_id" => tavern.id, "until" => WB_NOON - 1 } })
      described_class.refresh!(tavern, WB_NOON)
      expect(patron.reload.properties["pin"]).to be_nil
    end

    it "leaves corpses where they fell" do
      corpse = npc(location_id: tavern.id, home_location_id: mirehold.id, current_hp: 0)
      described_class.refresh!(tavern, WB_NIGHT)
      expect(corpse.reload.location_id).to eq(tavern.id)
    end

    it "is a cache read with no game_time" do
      away = npc(subrole: "smith", location_id: mirehold.id, home_location_id: smithy.id)
      expect(described_class.refresh!(smithy, nil)).not_to include(away)
      expect(away.reload.location_id).to eq(mirehold.id)
    end
  end

  describe ".pin!" do
    it "pins until the next day-phase boundary" do
      patron = npc(location_id: mirehold.id, home_location_id: mirehold.id)
      described_class.pin!(patron, tavern, WB_EVENING)
      pin = patron.reload.properties["pin"]
      expect(pin["location_id"]).to eq(tavern.id)
      expect(pin["until"]).to eq(22 * 60) # evening ends at 22:00
    end

    it "crosses midnight from late night to the morning boundary" do
      patron = npc(location_id: mirehold.id, home_location_id: mirehold.id)
      described_class.pin!(patron, tavern, WB_NIGHT)
      expect(patron.reload.properties["pin"]["until"]).to eq(24 * 60 + 6 * 60)
    end

    it "is a no-op without a game_time" do
      patron = npc(location_id: mirehold.id, home_location_id: mirehold.id)
      described_class.pin!(patron, tavern, nil)
      expect(patron.reload.properties["pin"]).to be_nil
    end
  end

  describe ".settle_transients!" do
    it "evaporates a pure-flavor transient and anchors an event-engaged one" do
      flavor  = npc(location_id: tavern.id, home_location_id: nil)
      engaged = npc(location_id: tavern.id, home_location_id: nil)
      event   = Event.create!(game_time: WB_NOON, location_id: tavern.id, details: {}, scope: "local")
      EventParticipant.create!(event: event, character_id: engaged.id, role: "actor")

      described_class.settle_transients!([ flavor, engaged ], tavern)

      expect(Npc.exists?(flavor.id)).to be(false)
      expect(engaged.reload.home_location_id).to eq(tavern.id)
    end

    it "never touches anchored cast, corpses, or followers" do
      anchored = npc(location_id: tavern.id, home_location_id: mirehold.id)
      corpse   = npc(location_id: tavern.id, home_location_id: nil, current_hp: 0)
      pal      = npc(location_id: tavern.id, home_location_id: nil, properties: { "following_player" => true })

      described_class.settle_transients!([ anchored, corpse, pal ], tavern)

      expect(anchored.reload.home_location_id).to eq(mirehold.id)
      expect(Npc.exists?(corpse.id)).to be(true)
      expect(pal.reload.home_location_id).to be_nil
    end
  end

  describe ".due_here?" do
    it "is true only at the meeting place inside the window" do
      player = Player.create!(name: "Hero", location_id: mirehold.id)
      other  = npc(location_id: mirehold.id, home_location_id: mirehold.id)
      Obligation.create!(kind: "meet", status: "open", debtor: other, creditor: player,
                         terms: "meet at the tavern", due_time: WB_NOON + 30, location_id: tavern.id)
      expect(described_class.due_here?(tavern, WB_NOON)).to be(true)
      expect(described_class.due_here?(smithy, WB_NOON)).to be(false)
      expect(described_class.due_here?(tavern, WB_NOON + 5000)).to be(false)
    end
  end
end
