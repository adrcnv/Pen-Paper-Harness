require "rails_helper"

RSpec.describe "Harness::Tools::Resolve — ability mode" do
  let(:tavern) { Location.create!(name: "Tavern") }

  let(:player) {
    Player.create!(
      name: "Hero", location: tavern,
      strength: 14, dexterity: 12, constitution: 12,
      intelligence: 16, wisdom: 10, charisma: 10,
      abilities: [
        {
          "name" => "Fireball",
          "description" => "A ranged burst of fire",
          "stat" => "intelligence",
          "opposed_by" => "dexterity",
          "difficulty" => "moderate",
          "uses_per_rest"  => 3,
          "uses_remaining" => 3,
          "effect_kind"    => "damage",
          "tags" => [ "arcane", "fire" ]
        },
        {
          "name" => "Detect Magic",
          "description" => "Sense active magic nearby",
          "stat" => "wisdom",
          "opposed_by" => nil,
          "difficulty" => "easy",
          "uses_per_rest"  => 5,
          "uses_remaining" => 5,
          "effect_kind"    => "buff",
          "tags" => [ "arcane", "utility" ]
        }
      ]
    )
  }

  let(:bandit) {
    Npc.create!(
      name: "Bandit", subrole: "bandit", location: tavern,
      strength: 10, dexterity: 10, constitution: 10,
      intelligence: 8, wisdom: 8, charisma: 6,
      abilities: []
    )
  }

  let(:context) { Harness::Turn::Context.new(player_location: tavern, game_time: 100) }

  def stub_dice(result: "success", margin: "clear", critical: false)
    allow(::Harness::Dice).to receive(:check).and_return(
      ::Harness::Dice::Outcome.new(result: result, margin: margin, critical: critical)
    )
  end

  describe "lookup" do
    it "finds an ability by case-insensitive name" do
      stub_dice
      out = Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "ability_name" => "fireball", "action" => "burn the bandit", "target_id" => bandit.id },
        context
      )
      expect(out["ability_name"]).to eq("Fireball")
      expect(out["outcome"]).to eq("success")
    end

    it "errors when the ability isn't on the actor, listing available abilities" do
      out = Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "ability_name" => "Lightning Bolt", "action" => "zap" },
        context
      )
      expect(out["error"]).to match(/not on actor/)
      expect(out["error"]).to match(/Fireball/)
      expect(out["error"]).to match(/Detect Magic/)
    end

    it "errors when actor has empty abilities list, suggesting stat check fallback" do
      out = Harness::Tools::Resolve.new.call(
        { "actor_id" => bandit.id, "ability_name" => "Fireball", "action" => "burn" },
        context
      )
      expect(out["error"]).to match(/no abilities/)
      expect(out["error"]).to match(/stat check/)
    end
  end

  describe "stat override" do
    it "uses ability.stat, ignoring any stat arg" do
      expect(::Harness::Dice).to receive(:check).with(
        hash_including(actor_stat: 16)  # player's intelligence, not strength
      ).and_return(::Harness::Dice::Outcome.new(result: "success", margin: "narrow", critical: false))

      Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "ability_name" => "Fireball", "stat" => "strength", "action" => "burn", "target_id" => bandit.id },
        context
      )
    end

    it "uses ability.opposed_by for target stat (overrides target_stat arg)" do
      expect(::Harness::Dice).to receive(:check).with(
        hash_including(actor_stat: 16, target_stat: 10)  # bandit.dexterity
      ).and_return(::Harness::Dice::Outcome.new(result: "success", margin: "narrow", critical: false))

      Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "ability_name" => "Fireball", "target_id" => bandit.id, "target_stat" => "wisdom", "action" => "burn" },
        context
      )
    end

    it "unopposed ability ignores target for roll math but keeps them as participant" do
      expect(::Harness::Dice).to receive(:check).with(
        hash_including(target_stat: nil, difficulty: "easy")  # Detect Magic: opposed_by null, difficulty easy
      ).and_return(::Harness::Dice::Outcome.new(result: "success", margin: "clear", critical: false))

      out = Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "ability_name" => "Detect Magic", "action" => "check for magic", "target_id" => bandit.id },
        context
      )
      expect(out["target_id"]).to eq(bandit.id)
      # Target is recorded as participant even though the roll is unopposed.
      ev = Event.last
      roles = ev.event_participants.map(&:role)
      expect(roles).to contain_exactly("actor", "target")
    end

    it "uses ability.difficulty as default" do
      expect(::Harness::Dice).to receive(:check).with(
        hash_including(difficulty: "easy")
      ).and_return(::Harness::Dice::Outcome.new(result: "success", margin: "narrow", critical: false))

      Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "ability_name" => "Detect Magic", "action" => "scan the room" },
        context
      )
    end

    it "explicit difficulty arg overrides ability.difficulty" do
      expect(::Harness::Dice).to receive(:check).with(
        hash_including(difficulty: "hard")
      ).and_return(::Harness::Dice::Outcome.new(result: "failure", margin: "narrow", critical: false))

      Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "ability_name" => "Detect Magic", "action" => "scan", "difficulty" => "hard" },
        context
      )
    end
  end

  describe "event logging" do
    it "includes ability_name in the event details" do
      stub_dice
      Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "ability_name" => "Fireball", "target_id" => bandit.id, "action" => "burn" },
        context
      )
      expect(Event.last.details["resolve"]).to include("ability_name" => "Fireball")
    end
  end

  describe "stat-only mode backward compatibility" do
    it "still works when ability_name is absent" do
      stub_dice
      out = Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "stat" => "strength", "action" => "punch" },
        context
      )
      expect(out["outcome"]).to eq("success")
      expect(out["ability_name"]).to be_nil
    end

    it "still requires stat when ability_name absent" do
      out = Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "action" => "do something vague" },
        context
      )
      expect(out["error"]).to match(/stat must be one of/)
    end
  end

  describe "ability lookup against character.abilities" do
    # Eager-Hatchery world: abilities are committed at character creation
    # by Abilities::Assigner, not lazy-materialized at resolve time. These
    # tests verify the resolve-time lookup against the abilities array
    # the Hatchery would have populated.

    it "uses the caster's class primary_stat when the ability omits a stat override" do
      mage_npc = Npc.create!(
        name: "Arwen", subrole: "scholar", location: tavern,
        character_class: "mage",
        strength: 8, dexterity: 10, constitution: 10,
        intelligence: 16, wisdom: 14, charisma: 12,
        abilities: [
          {
            "name"           => "Arcane Bolt",
            "description"    => "thin streak of pale force",
            "classes"        => [ "mage" ],
            "min_level"      => 1,
            "effect_kind"    => "damage",
            "range"          => "far",
            "uses_per_rest"  => 4,
            "uses_remaining" => 4,
            "opposed_by"     => "dexterity"
            # no "stat" — should fall back to mage's primary_stat = intelligence
          }
        ]
      )
      stub_dice

      out = Harness::Tools::Resolve.new.call(
        { "actor_id" => mage_npc.id, "ability_name" => "Arcane Bolt", "action" => "cast bolt", "target_id" => player.id },
        context
      )
      expect(out["outcome"]).to eq("success")
      expect(out["ability_name"]).to eq("Arcane Bolt")
    end

    it "errors clearly when ability isn't on the actor's list (no lazy materialization)" do
      maren = Npc.create!(name: "Maren", subrole: "barkeep", location: tavern, abilities: [])

      out = Harness::Tools::Resolve.new.call(
        { "actor_id" => maren.id, "ability_name" => "Fireball", "action" => "burn" },
        context
      )
      expect(out["error"]).to match(/no abilities/)
      expect(maren.reload.abilities).to eq([])
    end
  end
end
