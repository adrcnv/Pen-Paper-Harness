require "rails_helper"

RSpec.describe Harness::Tools::Transition do
  let(:city)    { Location.create!(name: "Saltmere") }
  let(:tavern)  { Location.create!(name: "Tavern", parent: city) }
  let(:warehouse) { Location.create!(name: "Warehouse", parent: city) }
  let!(:player) { Player.create!(name: "Hero", location: tavern) }
  let(:context) {
    # Noon — day phase, so the Warehouse (a trade venue) is open and the
    # barred-door gate stays out of the mechanics tests' way.
    Harness::Turn::Context.new(player_location: tavern, game_time: 720).tap { |c|
      c.active_scene = Harness::Scene::Active.new(
        location: tavern, snapshot: nil, narrations: [], internal_state: {}, agendas: {}, extras: [],
        entered_at_game_time: 720
      )
    }
  }

  describe "happy path" do
    it "moves the player to a sibling sublocation, advances clock, sets scene_dirty" do
      out = described_class.new.call({ "destination_id" => warehouse.id }, context)
      expect(out["error"]).to be_nil
      expect(context.player_location).to eq(warehouse)
      expect(context.scene_dirty).to be(true)
      expect(player.reload.location_id).to eq(warehouse.id)
    end
  end

  describe "follower relocation" do
    it "relocates flagged followers along with the player on transition" do
      elara = Npc.create!(name: "Elara", location: tavern, character_class: "fighter",
                          properties: { "following_player" => true })

      out = described_class.new.call({ "destination_id" => warehouse.id }, context)

      expect(elara.reload.location_id).to eq(warehouse.id)
      expect(out["followers_relocated"]).to eq([ { "id" => elara.id, "name" => "Elara" } ])
    end

    it "leaves non-flagged NPCs at the origin location" do
      bystander = Npc.create!(name: "Patron", location: tavern, character_class: "commoner",
                              properties: { "following_player" => false })
      no_flag   = Npc.create!(name: "Bartender", location: tavern, character_class: "commoner")

      described_class.new.call({ "destination_id" => warehouse.id }, context)

      expect(bystander.reload.location_id).to eq(tavern.id)
      expect(no_flag.reload.location_id).to eq(tavern.id)
    end

    it "omits followers_relocated from the response when none follow" do
      out = described_class.new.call({ "destination_id" => warehouse.id }, context)
      expect(out).not_to have_key("followers_relocated")
    end

    it "relocates multiple followers in one move" do
      a = Npc.create!(name: "Marta", location: tavern, character_class: "fighter",
                      properties: { "following_player" => true })
      b = Npc.create!(name: "Korr",  location: tavern, character_class: "rogue",
                      properties: { "following_player" => true })

      described_class.new.call({ "destination_id" => warehouse.id }, context)

      [ a, b ].each { |c| expect(c.reload.location_id).to eq(warehouse.id) }
    end
  end

  describe "barred doors (venue hours)" do
    NIGHT_TIME = 23 * 60

    it "refuses a shut trade venue at night, player unmoved" do
      context.game_time = NIGHT_TIME
      out = described_class.new.call({ "destination_id" => warehouse.id }, context)
      expect(out["refused"]).to eq("closed")
      expect(context.player_location).to eq(tavern)
      expect(context.game_time).to eq(NIGHT_TIME) # no clock cost on a refused door
    end

    it "never bars a tavern (night arrival is possible and safe)" do
      context.player_location = warehouse
      player.update!(location: warehouse)
      context.game_time = NIGHT_TIME
      out = described_class.new.call({ "destination_id" => tavern.id }, context)
      expect(out["error"]).to be_nil
      expect(context.player_location).to eq(tavern)
    end

    it "a due-now appointment at the venue opens the door" do
      keeper = Npc.create!(name: "Factor", location: warehouse, home_location: warehouse)
      Obligation.create!(debtor: keeper, creditor: player, kind: "meet",
                         terms: "Meet at the warehouse", due_time: NIGHT_TIME + 30,
                         game_time: 0, location_id: warehouse.id)
      context.game_time = NIGHT_TIME
      out = described_class.new.call({ "destination_id" => warehouse.id }, context)
      expect(out["error"]).to be_nil
      expect(context.player_location).to eq(warehouse)
    end
  end
end
