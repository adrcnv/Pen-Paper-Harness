require "rails_helper"

RSpec.describe Harness::Character::ActiveEffects do
  let(:loc)  { Location.create!(name: "Yard") }
  let(:hero) { Player.create!(name: "Hero", location: loc) }

  def bless   = { "id" => "bless", "name" => "Bless", "effect" => { "duration_minutes" => 30, "roll_modifier" => 2 } }
  def shield  = { "id" => "shield_up", "name" => "Shield Up", "effect" => { "duration_minutes" => 10, "effects" => [ { "trigger" => "damage_resist", "params" => { "amount" => 2, "type" => nil } } ] } }
  def utility = { "id" => "prestidigitation", "name" => "Prestidigitation" } # no effect block

  it "applies an effect block with expiry, readable back while live and gone after" do
    described_class.apply!(hero, ability: bless, now: 100)
    expect(described_class.active_for(hero.reload, now: 100).map { |e| e["name"] }).to eq([ "Bless" ])
    expect(described_class.roll_modifier(hero, now: 100)).to eq(2)
    expect(described_class.active_for(hero, now: 100 + 30)).to be_empty
    expect(described_class.roll_modifier(hero, now: 100 + 30)).to eq(0)
  end

  it "returns nil (and stores nothing) for an ability without an effect block" do
    expect(described_class.apply!(hero, ability: utility, now: 100)).to be_nil
    expect(hero.reload.properties["active_effects"]).to be_nil
  end

  it "refreshes on recast (same source replaces, never stacks) and prunes expired corpses" do
    described_class.apply!(hero, ability: bless, now: 100)
    described_class.apply!(hero, ability: shield, now: 100)
    # bless expires at 130; recast at 200 → shield (expired at 110) pruned, bless refreshed
    described_class.apply!(hero, ability: bless, now: 200)

    stored = hero.reload.properties["active_effects"]
    expect(stored.size).to eq(1)
    expect(stored.first["source"]).to eq("bless")
    expect(stored.first["expires_at"]).to eq(230)
    expect(described_class.roll_modifier(hero, now: 200)).to eq(2) # refreshed, not doubled
  end

  it "feeds Modifiers.stat_bonus and TriggerRegistry.fire_phase when the clock is passed" do
    described_class.apply!(hero, ability: { "id" => "stone_skin", "name" => "Stone Skin",
      "effect" => { "duration_minutes" => 10, "modifiers" => [ { "stat" => "strength", "op" => "add", "value" => 2 } ],
                    "effects" => [ { "trigger" => "damage_resist", "params" => { "amount" => 2, "type" => nil } } ] } }, now: 100)

    expect(Harness::Items::Modifiers.stat_bonus(hero, "strength", now: 100)).to eq(2)
    expect(Harness::Items::Modifiers.stat_bonus(hero, "strength")).to eq(0)          # clockless read = items only
    expect(Harness::Items::Modifiers.stat_bonus(hero, "strength", now: 111)).to eq(0) # expired

    out = Harness::Items::TriggerRegistry.fire_phase(phase: :on_damage_taken, actor: hero, damage: 5, now: 100)
    expect(out[:damage_modifier]).to eq(-2)
    expect(out[:triggered].first).to include(trigger: "damage_resist", item_id: nil)

    out_expired = Harness::Items::TriggerRegistry.fire_phase(phase: :on_damage_taken, actor: hero, damage: 5, now: 111)
    expect(out_expired[:damage_modifier]).to be_nil
  end
end
