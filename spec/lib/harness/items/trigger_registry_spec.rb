require "rails_helper"

RSpec.describe Harness::Items::TriggerRegistry do
  let(:loc)    { Location.create!(name: "Cellar") }
  let(:actor)  { Npc.create!(name: "Korr",  location: loc, character_class: "fighter", level: 3, current_hp: 10, max_hp: 20) }
  let(:target) { Npc.create!(name: "Jorel", location: loc, character_class: "fighter", level: 3, current_hp: 8,  max_hp: 12) }

  describe ".known? / .lookup" do
    it "knows the registered triggers" do
      %w[death_save damage_resist heal_on_kill regen_on_rest bonus_damage_vs_tag crit_chance_bonus extra_attack reflect_damage restore_use auto_succeed_check].each do |name|
        expect(described_class.known?(name)).to be(true), "expected trigger=#{name} to be registered"
      end
    end

    it "raises UnknownTrigger for unregistered names" do
      expect(described_class.known?("make_immortal")).to be(false)
      expect { described_class.lookup("make_immortal") }.to raise_error(described_class::UnknownTrigger)
    end
  end

  describe ".validate_params!" do
    it "passes with correct shapes" do
      expect { described_class.validate_params!("death_save", { "hp_after" => 1, "destroy_on_use" => true }) }.not_to raise_error
      expect { described_class.validate_params!("damage_resist", { "amount" => 2, "type" => "fire" }) }.not_to raise_error
      expect { described_class.validate_params!("damage_resist", { "amount" => 2, "type" => nil }) }.not_to raise_error
    end

    it "raises InvalidParams on shape mismatch" do
      expect {
        described_class.validate_params!("death_save", { "hp_after" => "one", "destroy_on_use" => true })
      }.to raise_error(described_class::InvalidParams, /hp_after/)
    end
  end

  describe ".fire_phase" do
    def equip(actor, trigger:, params:, name: "Token")
      Item.create!(
        name:         name,
        character_id: actor.id,
        properties:   { "tags" => [], "modifiers" => [], "effects" => [ { "trigger" => trigger, "params" => params } ] }
      )
    end

    it "fires death_save and writes revive_to_hp into the outcome" do
      equip(target, trigger: "death_save", params: { "hp_after" => 1, "destroy_on_use" => false })
      outcome = described_class.fire_phase(phase: :on_lethal, actor: target)
      expect(outcome[:revive_to_hp]).to eq(1)
    end

    it "death_save with destroy_on_use removes the item" do
      item = equip(target, trigger: "death_save", params: { "hp_after" => 1, "destroy_on_use" => true })
      described_class.fire_phase(phase: :on_lethal, actor: target)
      expect(Item.find_by(id: item.id)).to be_nil
    end

    it "damage_resist reduces incoming damage via outcome[:damage_modifier]" do
      equip(target, trigger: "damage_resist", params: { "amount" => 3, "type" => nil })
      outcome = described_class.fire_phase(phase: :on_damage_taken, actor: target, damage: 10)
      expect(outcome[:damage_modifier]).to eq(-3)
    end

    it "damage_resist type-gated: only fires when the ability tags include the type" do
      equip(target, trigger: "damage_resist", params: { "amount" => 3, "type" => "fire" })
      ability_fire = { "tags" => [ "fire", "arcane" ] }
      ability_cold = { "tags" => [ "cold", "arcane" ] }

      out_fire = described_class.fire_phase(phase: :on_damage_taken, actor: target, damage: 10, ability: ability_fire)
      out_cold = described_class.fire_phase(phase: :on_damage_taken, actor: target, damage: 10, ability: ability_cold)

      expect(out_fire[:damage_modifier]).to eq(-3)
      expect(out_cold[:damage_modifier]).to be_nil
    end

    it "no-ops cleanly when actor has no items" do
      out = described_class.fire_phase(phase: :on_lethal, actor: target)
      expect(out).to eq({})
    end

    it "ignores phases the trigger isn't registered for" do
      equip(target, trigger: "death_save", params: { "hp_after" => 1, "destroy_on_use" => false })
      out = described_class.fire_phase(phase: :on_rest, actor: target)
      expect(out[:revive_to_hp]).to be_nil  # death_save is on_lethal, not on_rest
    end
  end
end
