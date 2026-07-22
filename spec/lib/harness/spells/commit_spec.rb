require "rails_helper"

RSpec.describe Harness::Spells::Commit do
  let(:town)  { Location.create!(name: "Saltmere") }
  let(:yard)  { Location.create!(name: "Yard", parent: town) }
  let!(:caster) {
    Player.create!(
      name: "Hero", location: yard,
      strength: 10, dexterity: 10, constitution: 10, intelligence: 10, wisdom: 10, charisma: 10,
      max_hp: 20, current_hp: 20, coins: 10
    )
  }
  let!(:mark) {
    Npc.create!(name: "Maren", subrole: "fisher", location: yard,
                strength: 10, dexterity: 10, constitution: 10, intelligence: 10, wisdom: 10, charisma: 10,
                max_hp: 12, current_hp: 12, coins: 3)
  }
  let(:context) { Harness::Turn::Context.new(player_location: yard, game_time: 700) }
  let(:spell)   { { "id" => "test_spell", "name" => "Test Spell", "description" => "does spell things" } }

  def run(atoms, target: mark, narrative: "the working takes hold")
    described_class.run(atoms: atoms, spell: spell, caster: caster, target: target, context: context, narrative: narrative)
  end

  it "commits damage, heal, timed_effect, and coins in order, then logs ONE composite narrative event" do
    caster.update!(current_hp: 5)
    out = run([
      { "kind" => "damage", "who" => "target", "dice" => "3" },
      { "kind" => "heal", "who" => "caster", "dice" => "4" },
      { "kind" => "timed_effect", "who" => "target", "name" => "Marked", "duration_minutes" => 10, "roll_modifier" => -1 },
      { "kind" => "coins", "who" => "caster", "delta" => 25 }
    ])

    expect(out["errors"]).to eq([])
    expect(mark.reload.current_hp).to eq(9)
    expect(caster.reload.current_hp).to eq(9)
    expect(Harness::Character::ActiveEffects.roll_modifier(mark, now: 700)).to eq(-1)
    expect(caster.coins).to eq(35)

    ev = Event.order(:id).last
    expect(ev.details.dig("narrative", "trigger")).to eq("cast Test Spell")
    expect(ev.details.dig("narrative", "details")).to eq("the working takes hold")
    expect(ev.details.dig("spell", "atoms")).to eq(%w[damage heal timed_effect coins])
    expect(ev.event_participants.map(&:role)).to contain_exactly("actor", "target")
    # The composite event is the recallable record; per-atom logs stay audit-only.
    expect(Event.queryable.where(id: ev.id)).to exist
  end

  it "skips invalid atoms and target-refs with no bound target, still committing the rest" do
    out = run([
      { "kind" => "damage", "who" => "target", "dice" => "2" },
      { "kind" => "summon_demon" },
      { "kind" => "coins", "who" => "caster", "delta" => 5 }
    ], target: nil)

    expect(out["errors"].size).to eq(2)
    expect(caster.reload.coins).to eq(15)
    expect(Event.order(:id).last.details.dig("spell", "atoms")).to eq(%w[coins])
  end

  it "mutates characters through the tool (clamps intact) and permanent changes persist" do
    out = run([ { "kind" => "mutate_character", "who" => "target", "field" => "charisma", "value" => 99 } ])
    expect(out["errors"]).to eq([])
    expect(mark.reload.charisma).to eq(30)
  end

  it "teleports the caster, updating context.player_location and dirtying the scene" do
    keep = Location.create!(name: "The Old Wharf", parent: town)
    out = run([ { "kind" => "teleport", "who" => "caster", "destination" => "the old wharf" } ], target: nil)

    expect(out["scene_dirty"]).to be(true)
    expect(caster.reload.location_id).to eq(keep.id)
    expect(context.player_location.id).to eq(keep.id)
  end

  it "binds and releases followers (NPCs only, never the caster)" do
    run([ { "kind" => "follower", "who" => "target", "attach" => true } ])
    expect(mark.reload.properties["following_player"]).to be(true)

    run([ { "kind" => "follower", "who" => "target", "attach" => false } ])
    expect(mark.reload.properties).not_to have_key("following_player")

    out = run([ { "kind" => "follower", "who" => "caster", "attach" => true } ], target: nil)
    expect(out["errors"].first).to match(/cannot follow themselves/)
  end

  it "conjures a being at the caster's location; follow binds it in the same stroke" do
    out = run([ { "kind" => "create_character", "subrole" => "hound", "description" => "a shape of smoke and teeth", "follow" => true } ], target: nil)

    expect(out["errors"]).to eq([])
    expect(out["scene_dirty"]).to be(true)
    made = Npc.order(:id).last
    expect(made.location_id).to eq(yard.id)
    expect(made.subrole).to eq("hound")
    expect(made.properties["following_player"]).to be(true)
    expect(made.properties["physical"]).to match(/smoke and teeth/)
  end

  it "mints items, alters the location, and plants knowledge anchored at the enclosing settlement" do
    out = run([
      { "kind" => "mint_item", "name" => "Glass Rose", "subrole" => "curio", "to" => "target" },
      { "kind" => "alter_location", "alteration" => "frost patterns the walls" },
      { "kind" => "write_knowledge", "content" => "roses of glass grow where the mage walked" }
    ])

    expect(out["errors"]).to eq([])
    expect(Item.find_by(name: "Glass Rose").character_id).to eq(mark.id)
    expect(yard.reload.properties["alterations"]).to include("frost patterns the walls")
    row = Knowledge.order(:id).last
    expect(row.content).to match(/roses of glass/)
    expect(row.location_id).to eq(town.id)
    expect(row.source_kind).to eq("spell")
    expect(row.speaker).to eq("Hero")
  end

  it "revives the downed and advances the clock" do
    mark.update!(current_hp: 0, properties: { "stance" => "downed" })
    out = run([
      { "kind" => "revive", "who" => "target", "hp" => 5 },
      { "kind" => "advance_clock", "minutes" => 90 }
    ])

    expect(out["errors"]).to eq([])
    expect(mark.reload.current_hp).to eq(5)
    expect(mark.properties).not_to have_key("stance")
    expect(context.game_time).to eq(790)
  end

  it "rescues a raising atom and keeps going" do
    allow(Harness::Abilities::DiceFormula).to receive(:roll).and_raise(RuntimeError, "boom")
    out = run([
      { "kind" => "damage", "who" => "target", "dice" => "1d6" },
      { "kind" => "coins", "who" => "target", "delta" => 2 }
    ])

    expect(out["errors"].first).to match(/damage failed: boom/)
    expect(mark.reload.coins).to eq(5)
  end
end
