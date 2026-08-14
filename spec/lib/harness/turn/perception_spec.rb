require "rails_helper"

RSpec.describe Harness::Turn::Perception do
  let(:tavern)  { Location.create!(name: "Tavern", description: "Low beams, peat smoke.") }
  let!(:player) { Player.create!(name: "Hero", location: tavern) }

  def ctx(llm: nil)
    Harness::Turn::Context.new(player_location: tavern, game_time: 720, llm_nuance: llm)
  end

  it "returns nil without an LLM client (specs and degraded sessions stay silent)" do
    expect(described_class.render(context: ctx, parts: [])).to be_nil
  end

  it "renders prose from observable state: place, hour, people with stored appearance, just_now" do
    Npc.create!(name: "Bess", subrole: "barkeep", location: tavern,
                properties: { "appearance" => "flour-dusted forearms, a squint" })
    llm = StubLLM.new { "Bess wipes down the bar." }
    text = described_class.render(
      context: ctx(llm: llm),
      parts: [ { kind: :line, text: "You take the locket." } ]
    )
    expect(text).to eq("Bess wipes down the bar.")
    input = llm.user_calls.last
    expect(input).to include('"Tavern"')
    expect(input).to include("flour-dusted forearms")
    expect(input).to include('"time_of_day": "day"')
    expect(input).to include("You take the locket.")
    # Eyes see no engine bookkeeping: no ids, no agendas.
    expect(input).not_to include('"id"')
    expect(input).not_to include('"agenda"')
  end

  it "swallows a flaked call — the mechanical parts carry the turn" do
    llm = StubLLM.new { raise "connection refused" }
    expect(described_class.render(context: ctx(llm: llm), parts: [])).to be_nil
  end

  it "returns nil on a blank emit" do
    llm = StubLLM.new { "  " }
    expect(described_class.render(context: ctx(llm: llm), parts: [])).to be_nil
  end
end
