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

  it "surfaces the taking-stock activity microbeat as the person's `doing`" do
    bess = Npc.create!(name: "Bess", subrole: "barkeep", location: tavern)
    active = Harness::Scene::Active.new(location: tavern, snapshot: nil, narrations: [])
    active.update_doing!(bess.id, "stacking tankards behind the bar")
    llm = StubLLM.new { "Bess stacks tankards." }
    context = ctx(llm: llm)
    context.active_scene = active

    described_class.render(context: context, parts: [])
    expect(llm.user_calls.last).to include("stacking tankards behind the bar")
  end

  it "withholds figures (extras) on a non-establishing render — no writer, never a delta" do
    active = Harness::Scene::Active.new(location: tavern, snapshot: nil, narrations: [],
                                        extras: [ "a lone gull crying over the water" ])
    llm = StubLLM.new { "The room holds still." }
    context = ctx(llm: llm)
    context.active_scene = active

    described_class.render(context: context, parts: [], include_figures: false)
    expect(llm.user_calls.last).not_to include("lone gull")

    described_class.render(context: context, parts: [], include_figures: true)
    expect(llm.user_calls.last).to include("lone gull")
  end

  it "eyes don't hear: dialogue parts are excluded from just_now" do
    llm = StubLLM.new { "The room holds still." }
    described_class.render(
      context: ctx(llm: llm),
      parts: [
        { kind: :dialogue, text: "\"Look at that wall Sindri threw up.\"" },
        { kind: :line, text: "You take the locket." }
      ]
    )
    input = llm.user_calls.last
    expect(input).not_to include("wall Sindri")
    expect(input).to include("You take the locket.")
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
