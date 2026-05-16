require "rails_helper"

RSpec.describe Harness::Quests::FulfillmentCheck do
  let(:city) { Location.create!(name: "Helmrest", parent: nil, x: 0.0, y: 0.0, biome: "lowland") }
  let(:player) { Player.create!(name: "Alyx", subrole: "wanderer", location_id: city.id, current_hp: 10, max_hp: 10, level: 1, character_class: "ranger") }
  let(:giver) { Npc.create!(name: "Marcus", subrole: "merchant", location_id: city.id, current_hp: 5, max_hp: 5, level: 1, character_class: "commoner") }
  let(:informant) { Npc.create!(name: "Torvin", subrole: "dockhand", location_id: city.id, current_hp: 5, max_hp: 5, level: 1, character_class: "commoner") }
  let(:antagonist) { Npc.create!(name: "Vorr", subrole: "bandit", location_id: city.id, current_hp: 5, max_hp: 5, level: 1, character_class: "commoner") }
  let(:target_loc) { Location.create!(name: "Salt Quarry", parent: city) }
  let(:target_item) { Item.create!(name: "Manifest case", subrole: "document", location: target_loc) }

  let(:context) { instance_double("Harness::Turn::Context", game_time: 100_010) }

  before do
    player; giver; informant; antagonist; target_loc; target_item
  end

  def build_quest(steps_attrs)
    q = Quest.create!(
      name:               "Q",
      summary:             "x",
      archetype_id:        "missing_courier",
      state:               "active",
      giver_character_id:  giver.id,
      city_location_id:    city.id
    )
    steps_attrs.each_with_index { |a, i| QuestStep.create!(a.merge(quest: q, position: i + 1)) }
    q
  end

  describe "information step" do
    it "fulfills when player and informant share a post-opening event" do
      quest = build_quest([
        { description: "speak with Torvin", state: "active", fulfillment_kind: "information", target_character_id: informant.id, opened_at_game_time: 100_000 }
      ])

      event = Event.create!(game_time: 100_005, scope: "personal", location: city, details: {})
      EventParticipant.create!(event: event, character: player, role: "actor")
      EventParticipant.create!(event: event, character: informant, role: "witness")

      described_class.run!(context)
      quest.reload
      expect(quest.state).to eq("complete")
    end

    it "does NOT fulfill on events committed BEFORE opened_at_game_time" do
      quest = build_quest([
        { description: "speak with Torvin", state: "active", fulfillment_kind: "information", target_character_id: informant.id, opened_at_game_time: 100_000 }
      ])

      event = Event.create!(game_time: 90_000, scope: "personal", location: city, details: {})
      EventParticipant.create!(event: event, character: player, role: "actor")
      EventParticipant.create!(event: event, character: informant, role: "witness")

      described_class.run!(context)
      quest.reload
      expect(quest.state).to eq("active")
    end
  end

  describe "item_in_inventory step" do
    it "fulfills when target item is in player's inventory" do
      quest = build_quest([
        { description: "get the manifest", state: "active", fulfillment_kind: "item_in_inventory", target_item_id: target_item.id, opened_at_game_time: 100_000 }
      ])
      target_item.update!(location: nil, character: player)

      described_class.run!(context)
      quest.reload
      expect(quest.state).to eq("complete")
    end
  end

  describe "character_dead step" do
    it "fulfills when target's current_hp <= 0" do
      quest = build_quest([
        { description: "kill Vorr", state: "active", fulfillment_kind: "character_dead", target_character_id: antagonist.id, opened_at_game_time: 100_000 }
      ])
      antagonist.update!(current_hp: 0)

      described_class.run!(context)
      quest.reload
      expect(quest.state).to eq("complete")
    end
  end

  describe "character_at_location step" do
    it "fulfills when target is at the target location" do
      quest = build_quest([
        { description: "bring Vorr to the Quarry", state: "active", fulfillment_kind: "character_at_location", target_character_id: antagonist.id, target_location_id: target_loc.id, opened_at_game_time: 100_000 }
      ])
      antagonist.update!(location: target_loc)

      described_class.run!(context)
      quest.reload
      expect(quest.state).to eq("complete")
    end
  end

  describe "step promotion (not last step)" do
    it "promotes next pending step rather than completing the quest" do
      quest = build_quest([
        { description: "speak with Torvin", state: "active",  fulfillment_kind: "information", target_character_id: informant.id, opened_at_game_time: 100_000 },
        { description: "kill Vorr",          state: "pending", fulfillment_kind: "character_dead", target_character_id: antagonist.id }
      ])

      event = Event.create!(game_time: 100_005, scope: "personal", location: city, details: {})
      EventParticipant.create!(event: event, character: player, role: "actor")
      EventParticipant.create!(event: event, character: informant, role: "witness")

      described_class.run!(context)
      quest.reload
      expect(quest.state).to eq("active")
      expect(quest.quest_steps.order(:position).map(&:state)).to eq(%w[fulfilled active])
      expect(quest.quest_steps.find_by(position: 2).opened_at_game_time).to eq(100_010)
    end
  end
end
