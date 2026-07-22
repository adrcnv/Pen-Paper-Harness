require "rails_helper"

RSpec.describe Harness::Spells::Composer do
  let(:yard) { Location.create!(name: "Yard") }
  let(:caster) {
    Player.create!(
      name: "Hero", location: yard, character_class: "mage", level: 13,
      strength: 10, dexterity: 10, constitution: 10, intelligence: 16, wisdom: 10, charisma: 10,
      max_hp: 20, current_hp: 20
    )
  }
  let(:spell) { { "id" => "wish", "name" => "Wish", "description" => "the world strains to oblige", "effect_kind" => "utility" } }

  def good_json
    { "narrative" => "the air folds and coin rains down",
      "atoms" => [ { "kind" => "coins", "who" => "caster", "delta" => 100 } ] }.to_json
  end

  it "returns the validated block in target-agnostic mode (no target/intent in the payload)" do
    stub = StubLLM.new { good_json }
    out = described_class.new(llm: stub).compose(spell: spell, caster: caster)

    expect(out["atoms"].first["kind"]).to eq("coins")
    expect(out["narrative"]).to match(/coin rains/)
    expect(stub.user_calls.first).not_to include('"target"', '"cast"')
  end

  it "volatile mode puts the worded intent and the target's full sheet in front of the composer" do
    mark = Npc.create!(name: "Maren", subrole: "fisher", location: yard,
                       strength: 10, dexterity: 10, constitution: 10, intelligence: 10, wisdom: 10, charisma: 14,
                       max_hp: 12, current_hp: 12, coins: 3,
                       properties: { "appearance" => "weathered, salt-cracked hands" })
    stub = StubLLM.new { good_json }
    described_class.new(llm: stub).compose(
      spell: spell, caster: caster, target: mark, location: yard, intent: "I wish Maren were beautiful"
    )

    user = stub.user_calls.first
    expect(user).to include("I wish Maren were beautiful")
    expect(user).to include("weathered, salt-cracked hands")
    expect(user).to include('"charisma": 14')
  end

  it "repairs on invalid output and gives up as nil after retries" do
    calls = 0
    stub = StubLLM.new do |full|
      calls += 1
      calls == 1 ? { "narrative" => "x", "atoms" => [ { "kind" => "summon_demon" } ] }.to_json : good_json
    end
    out = described_class.new(llm: stub).compose(spell: spell, caster: caster)
    expect(calls).to eq(2)
    expect(stub.user_calls.last).to include("YOUR PREVIOUS OUTPUT WAS REJECTED")
    expect(out["atoms"].first["kind"]).to eq("coins")

    always_bad = described_class.new(llm: StubLLM.new { "not json at all" })
    expect(always_bad.compose(spell: spell, caster: caster)).to be_nil
  end
end
