require "rails_helper"

RSpec.describe "Harness::Tools::Resolve — damage path" do
  let(:tavern) { Location.create!(name: "Tavern") }

  let(:player) {
    Player.create!(
      name: "Hero", location: tavern, character_class: "mage", level: 5,
      strength: 10, dexterity: 12, constitution: 12,
      intelligence: 16, wisdom: 10, charisma: 10,
      max_hp: 30, current_hp: 30,
      abilities: [
        {
          "name"           => "Arcane Bolt",
          "description"    => "thin streak of pale force",
          "classes"        => [ "mage" ],
          "min_level"      => 1,
          "effect_kind"    => "damage",
          "damage_dice"    => "1d6+1d4",
          "damage_per_level" => "1d6",
          "range"          => "far",
          "uses_per_rest"  => 4,
          "uses_remaining" => 4,
          "opposed_by"     => "dexterity"
        }
      ]
    )
  }

  let(:bandit) {
    Npc.create!(
      name: "Bandit", subrole: "bandit", location: tavern,
      character_class: "fighter", level: 1,
      strength: 12, dexterity: 10, constitution: 10,
      intelligence: 8, wisdom: 8, charisma: 6,
      max_hp: 11, current_hp: 11,
      abilities: []
    )
  }

  let(:context) { Harness::Turn::Context.new(player_location: tavern, game_time: 100) }

  def stub_dice(result: "success", margin: "clear", critical: false)
    allow(::Harness::Dice).to receive(:check).and_return(
      ::Harness::Dice::Outcome.new(result: result, margin: margin, critical: critical)
    )
  end

  it "rolls damage on success and applies it to the target's current_hp" do
    stub_dice(result: "success")
    allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(7)

    out = Harness::Tools::Resolve.new.call(
      { "actor_id" => player.id, "ability_name" => "Arcane Bolt", "action" => "cast bolt", "target_id" => bandit.id },
      context
    )

    expect(out["damage"]).to eq(7)
    expect(out["outcome"]).to eq("success")
    expect(bandit.reload.current_hp).to eq(4)
    expect(bandit.properties).not_to include("stance" => "downed")
  end

  it "doubles damage on critical_success" do
    stub_dice(result: "critical_success", critical: true)
    allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(5)

    Harness::Tools::Resolve.new.call(
      { "actor_id" => player.id, "ability_name" => "Arcane Bolt", "action" => "blast", "target_id" => bandit.id },
      context
    )
    expect(bandit.reload.current_hp).to eq(11 - 10)  # 5 × 2
  end

  it "sets stance=downed when current_hp hits 0" do
    stub_dice(result: "success")
    allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(20)

    out = Harness::Tools::Resolve.new.call(
      { "actor_id" => player.id, "ability_name" => "Arcane Bolt", "action" => "obliterate", "target_id" => bandit.id },
      context
    )

    expect(bandit.reload.current_hp).to eq(0)
    expect(bandit.properties).to include("stance" => "downed")
    expect(out["target_downed"]).to be(true)
  end

  it "does NOT apply damage on a failed roll" do
    stub_dice(result: "failure")

    Harness::Tools::Resolve.new.call(
      { "actor_id" => player.id, "ability_name" => "Arcane Bolt", "action" => "miss", "target_id" => bandit.id },
      context
    )
    expect(bandit.reload.current_hp).to eq(11)
  end

  it "decrements uses_remaining on the actor's ability after use (success)" do
    stub_dice(result: "success")

    Harness::Tools::Resolve.new.call(
      { "actor_id" => player.id, "ability_name" => "Arcane Bolt", "action" => "x", "target_id" => bandit.id },
      context
    )

    expect(player.reload.abilities.first["uses_remaining"]).to eq(3)
  end

  it "decrements uses_remaining even on a missed roll (slot still spent)" do
    stub_dice(result: "failure")

    Harness::Tools::Resolve.new.call(
      { "actor_id" => player.id, "ability_name" => "Arcane Bolt", "action" => "x", "target_id" => bandit.id },
      context
    )

    expect(player.reload.abilities.first["uses_remaining"]).to eq(3)
  end

  it "refuses the call when uses_remaining is 0" do
    player.update!(abilities: [ player.abilities.first.merge("uses_remaining" => 0) ])

    out = Harness::Tools::Resolve.new.call(
      { "actor_id" => player.id, "ability_name" => "Arcane Bolt", "action" => "x", "target_id" => bandit.id },
      context
    )
    expect(out["error"]).to match(/no uses remaining/)
    expect(bandit.reload.current_hp).to eq(11)  # untouched
  end

  it "does NOT apply damage for non-damage abilities (buff/heal)" do
    player.update!(abilities: [ {
      "name"           => "Mending Light",
      "effect_kind"    => "heal",
      "damage_dice"    => "1d8+1d4",
      "uses_per_rest"  => 3,
      "uses_remaining" => 3
    } ])
    stub_dice(result: "success")

    out = Harness::Tools::Resolve.new.call(
      { "actor_id" => player.id, "ability_name" => "Mending Light", "stat" => "wisdom", "action" => "heal" },
      context
    )

    expect(out["damage"]).to be_nil
    # heal abilities don't yet have a target-HP path (deferred); just verify
    # the ability fires cleanly and decrements its use.
    expect(player.reload.abilities.first["uses_remaining"]).to eq(2)
  end

  describe "XP on kill" do
    it "awards XP when the player drops a previously-alive NPC" do
      stub_dice(result: "success")
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(20)

      out = Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "ability_name" => "Arcane Bolt", "action" => "obliterate", "target_id" => bandit.id },
        context
      )

      # bandit at level 1, player at level 5 — diff -4 = 0.25× base (1×50)
      expect(out["xp_gained"]).to eq(12)
      expect(player.reload.xp).to eq(12)
    end

    it "does NOT award XP for damage that doesn't drop the target" do
      stub_dice(result: "success")
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(3)

      out = Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "ability_name" => "Arcane Bolt", "action" => "scratch", "target_id" => bandit.id },
        context
      )

      expect(out["xp_gained"]).to be_nil
      expect(player.reload.xp).to eq(0)
    end

    it "does NOT award XP for hitting an already-downed target" do
      bandit.update!(current_hp: 0)
      stub_dice(result: "success")
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(20)

      out = Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "ability_name" => "Arcane Bolt", "action" => "overkill", "target_id" => bandit.id },
        context
      )

      expect(out["xp_gained"]).to be_nil
      expect(player.reload.xp).to eq(0)
    end

    it "auto-levels-up when XP crosses threshold" do
      bandit.update!(level: 10)  # killing 5 levels up: 2.0× base = 10×50×2 = 1000 XP
      player.update!(level: 5, xp: 800)  # 700 short of level 6 threshold (1500)
      stub_dice(result: "success")
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(50)

      out = Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "ability_name" => "Arcane Bolt", "action" => "kill", "target_id" => bandit.id },
        context
      )

      expect(out["leveled_up"]).to be(true)
      expect(out["new_level"]).to eq(6)
      expect(player.reload.level).to eq(6)
    end

    it "does NOT award XP for NPC-on-NPC kills (only player levels)" do
      attacker = Npc.create!(
        name: "Attacker", subrole: "bandit", location: tavern,
        character_class: "fighter", level: 5,
        strength: 14, dexterity: 12, constitution: 12,
        intelligence: 10, wisdom: 10, charisma: 10,
        max_hp: 30, current_hp: 30,
        abilities: [ {
          "name" => "Heavy Strike", "effect_kind" => "damage",
          "damage_dice" => "1d8", "damage_per_level" => "1d6",
          "min_level" => 1, "uses_per_rest" => 4, "uses_remaining" => 4,
          "opposed_by" => "dexterity"
        } ]
      )
      stub_dice(result: "success")
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(20)

      Harness::Tools::Resolve.new.call(
        { "actor_id" => attacker.id, "ability_name" => "Heavy Strike", "action" => "smash", "target_id" => bandit.id },
        context
      )

      expect(attacker.reload.xp).to eq(0)
      expect(bandit.reload.current_hp).to eq(0)  # bandit IS downed, just no XP
    end
  end
end
