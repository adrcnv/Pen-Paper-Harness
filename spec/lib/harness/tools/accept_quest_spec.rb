require "rails_helper"

RSpec.describe Harness::Tools::AcceptQuest do
  let(:tool) { described_class.new }
  let(:city) { Location.create!(name: "Helmrest", parent: nil, x: 0.0, y: 0.0, biome: "lowland") }
  let(:player) { Player.create!(name: "Alyx", subrole: "wanderer", location_id: city.id, current_hp: 10, max_hp: 10, level: 1, character_class: "ranger") }
  let(:giver) { Npc.create!(name: "Marcus", subrole: "merchant", location_id: city.id, current_hp: 5, max_hp: 5, level: 1, character_class: "commoner") }
  let(:context) do
    instance_double("Harness::Turn::Context",
      game_time:        50,
      active_scene:     instance_double("Harness::Scene::Active", present_characters: [ giver ], location: city),
      player_location:  city
    )
  end

  before { player; giver }

  def build_quest(state: "offered")
    q = Quest.create!(
      name:               "Recover the shipment",
      summary:             "x",
      archetype_id:        "missing_courier",
      state:               state,
      giver_character_id:  giver.id,
      city_location_id:    city.id
    )
    QuestStep.create!(quest: q, position: 1, description: "speak with witness", state: "pending", fulfillment_kind: "information", target_character_id: giver.id)
    q
  end

  it "transitions an offered quest to active when giver is present and player intent is clear" do
    quest = build_quest

    result = tool.call({ "quest_id" => quest.id }, context)

    expect(result["error"]).to be_nil
    expect(result["state"]).to eq("active")
    quest.reload
    expect(quest.state).to eq("active")
    expect(quest.quest_steps.first.state).to eq("active")
    expect(quest.quest_steps.first.opened_at_game_time).to eq(50)
  end

  it "refuses to accept when giver is not in present_characters" do
    quest = build_quest
    expect(context).to receive(:active_scene).and_return(
      instance_double("Harness::Scene::Active", present_characters: [], location: city)
    )

    result = tool.call({ "quest_id" => quest.id }, context)
    expect(result["error"]).to match(/not in present_characters/)
    quest.reload
    expect(quest.state).to eq("offered")
  end

  it "refuses to accept quests not in `offered` state" do
    quest = build_quest(state: "active")
    result = tool.call({ "quest_id" => quest.id }, context)
    expect(result["error"]).to match(/state=/)
  end

  it "logs an acceptance event tagging player and giver" do
    quest = build_quest
    expect { tool.call({ "quest_id" => quest.id }, context) }.to change(Event, :count).by(1)
    accept_ev = Event.last
    expect(accept_ev.event_participants.pluck(:character_id)).to contain_exactly(player.id, giver.id)
    expect(accept_ev.details.dig("quest", "accepted")).to eq(true)
  end
end
