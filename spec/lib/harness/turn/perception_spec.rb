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
    # The eyes know whose skull they're in — third-person references to the
    # player in bearing/doing lines must bind to "you".
    expect(input).to include('"you"')
    expect(input).to include('"Hero"')
  end

  it "shows what of note a person bears — a weapon, armour, a jewel — from their rows, never their everyday things" do
    bess = Npc.create!(name: "Bess", subrole: "barkeep", location: tavern, properties: { "appearance" => "a squint" })
    Item.create!(name: "heavy dirk", subrole: "weapon", character: bess, properties: { "tags" => [ "weapon" ] })
    Item.create!(name: "copper loop", subrole: "ring", character: bess, properties: { "tags" => %w[jewelry ring] })
    Item.create!(name: "heel of bread", subrole: "meal", character: bess, properties: { "tags" => [ "provision" ] })
    person = described_class.observable_view(ctx)["people"].find { |p| p["name"] == "Bess" }
    expect(person["carries"]).to eq([ "heavy dirk", "copper loop" ])
    llm = StubLLM.new { "Bess rests a hand on the dirk at her belt." }
    described_class.render(context: ctx(llm: llm), parts: [ { kind: :line, text: "You look around." } ])
    expect(llm.user_calls.last).to include('"carries"', "heavy dirk")
    expect(llm.user_calls.last).not_to include("heel of bread")
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

  it "shows a person's doing and disposition, never the interior mood line" do
    bess = Npc.create!(name: "Bess", subrole: "barkeep", location: tavern)
    active = Harness::Scene::Active.new(location: tavern, snapshot: nil, narrations: [],
                                        internal_state: { bess.id => "sour about the missed delivery" },
                                        doing: { bess.id => "polishing the bar" })
    context = ctx
    context.active_scene = active

    person = described_class.observable_view(context)["people"].find { |p| p["name"] == "Bess" }
    expect(person["doing"]).to eq("polishing the bar")
    expect(person["disposition"]).to eq("neutral")
    expect(person).not_to have_key("bearing")
    expect(person.values.join).not_to include("missed delivery")

    active.shift_disposition!(bess.id, "colder")
    person = described_class.observable_view(context)["people"].find { |p| p["name"] == "Bess" }
    expect(person["disposition"]).to eq("guarded")
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

  it "eyes don't hear and don't read dice: dialogue and bracket parts are excluded from just_now" do
    llm = StubLLM.new { "The room holds still." }
    described_class.render(
      context: ctx(llm: llm),
      parts: [
        { kind: :dialogue, text: "\"Look at that wall Sindri threw up.\"" },
        { kind: :bracket,  text: "[press Bess — Charisma 2 vs 18: failure]" },
        { kind: :line, text: "You take the locket." }
      ]
    )
    input = llm.user_calls.last
    expect(input).not_to include("wall Sindri")
    expect(input).not_to include("Charisma 2 vs 18")
    expect(input).to include("You take the locket.")
  end

  describe ".view_delta" do
    it "reports a moved person as name, role and the moved fields only; a newcomer whole; departures by name; other fields only when moved" do
      prev = { "people" => [ { "name" => "A", "role" => "porter", "appearance" => "lean", "doing" => "raking" }, { "name" => "B", "doing" => "sitting" } ],
               "time_of_day" => "day", "things" => [ "rake" ] }
      curr = { "people" => [ { "name" => "A", "role" => "porter", "appearance" => "lean", "doing" => "pacing" },
                             { "name" => "C", "role" => "cook", "appearance" => "round", "bearing" => "humming" } ],
               "time_of_day" => "evening", "things" => [ "rake" ] }
      d = described_class.view_delta(prev, curr)
      expect(d["people"]).to eq([ { "name" => "A", "role" => "porter", "doing" => "pacing" },
                                  { "name" => "C", "role" => "cook", "appearance" => "round", "bearing" => "humming" } ])
      expect(d["departed"]).to eq([ "B" ])
      expect(d["time_of_day"]).to eq("evening")
      expect(d).not_to have_key("things")
    end

    it "returns empty when nothing moved" do
      v = { "people" => [ { "name" => "A" } ], "time_of_day" => "day" }
      expect(described_class.view_delta(v, v)).to eq({})
    end
  end

  describe ".visible_shift?" do
    it "is false for a disposition flip alone, true for doing, a newcomer, a departure, or the hour" do
      expect(described_class.visible_shift?(nil)).to be(false)
      expect(described_class.visible_shift?({})).to be(false)
      expect(described_class.visible_shift?({ "people" => [ { "name" => "Bess", "role" => "barkeep", "disposition" => "hostile" } ] })).to be(false)
      expect(described_class.visible_shift?({ "people" => [ { "name" => "Bess", "role" => "barkeep", "doing" => "counting coin", "disposition" => "hostile" } ] })).to be(true)
      expect(described_class.visible_shift?({ "people" => [ { "name" => "Osric", "role" => "porter", "gender" => "male", "doing" => "arriving" } ] })).to be(true)
      expect(described_class.visible_shift?({ "departed" => [ "Bess" ] })).to be(true)
      expect(described_class.visible_shift?({ "time_of_day" => "evening" })).to be(true)
    end
  end

  it "a SHIFT render gives the model the place name, the hour and what changed — never the standing room" do
    Npc.create!(name: "Bess", subrole: "barkeep", location: tavern, current_hp: 5, max_hp: 5)
    llm = StubLLM.new { "The light goes amber." }
    described_class.render(context: ctx(llm: llm), parts: [], shift_only: true,
                           changed: { "people" => [ { "name" => "Bess", "role" => "barkeep", "doing" => "counting coin" } ] })
    input = llm.user_calls.last
    expect(input).to include('"changed"').and include("counting coin").and include('"Tavern"')
    expect(input).not_to include("peat smoke")     # the description is establishment material
    expect(input).not_to include('"people"' + ": [\n") if false
    expect(JSON.parse(input.sub(/\AINPUT:\n/, "")).keys).to contain_exactly("place", "time_of_day", "changed", "you")
    expect(input).to include('"time_of_day": "day"')   # a fact, or the model invents one

    described_class.render(context: ctx(llm: llm), parts: [], shift_only: true)   # nothing changed: place and hour only
    expect(JSON.parse(llm.user_calls.last.sub(/\AINPUT:\n/, "")).keys).to contain_exactly("place", "time_of_day", "you")

    described_class.render(context: ctx(llm: llm), parts: [])                     # establishment: the whole view
    expect(llm.user_calls.last).to include("peat smoke").and include('"people"')
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
