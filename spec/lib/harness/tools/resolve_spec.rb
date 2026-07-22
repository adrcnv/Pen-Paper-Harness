require "rails_helper"

RSpec.describe Harness::Tools::Resolve do
  let(:city)    { Location.create!(name: "Saltmere") }
  let(:tavern)  { Location.create!(name: "Tavern", parent: city) }

  # Player at tavern with known stats so outcomes are predictable.
  let(:player) {
    Player.create!(
      name: "Hero", location: tavern,
      strength: 14, dexterity: 12, constitution: 12,
      intelligence: 10, wisdom: 10, charisma: 10
    )
  }

  # Npc with stats already set (skips materialization).
  let(:bandit) {
    Npc.create!(
      name: "Bandit", subrole: "bandit", location: tavern,
      strength: 10, dexterity: 10, constitution: 10,
      intelligence: 8, wisdom: 8, charisma: 6
    )
  }

  let(:context) { Harness::Turn::Context.new(player_location: tavern, game_time: 100) }

  # Stub the Dice engine so outcomes are deterministic without a fixed RNG.
  def stub_dice_outcome(result:, margin: "clear", critical: false)
    allow(::Harness::Dice).to receive(:check).and_return(
      ::Harness::Dice::Outcome.new(result: result, margin: margin, critical: critical)
    )
  end

  describe "shape and validation" do
    it "requires actor_id" do
      out = described_class.new.call({ "stat" => "strength", "action" => "punch" }, context)
      expect(out["error"]).to match(/actor_id required/)
    end

    it "requires a valid stat from the six" do
      out = described_class.new.call({ "actor_id" => player.id, "stat" => "luck", "action" => "x" }, context)
      expect(out["error"]).to match(/stat must be one of/)
    end

    it "requires a non-empty action" do
      out = described_class.new.call({ "actor_id" => player.id, "stat" => "strength", "action" => "  " }, context)
      expect(out["error"]).to match(/action must be/)
    end

    it "rejects unknown actor_id" do
      out = described_class.new.call({ "actor_id" => 99_999, "stat" => "strength", "action" => "x" }, context)
      expect(out["error"]).to match(/no character/)
    end

    it "rejects unknown target_id" do
      out = described_class.new.call(
        { "actor_id" => player.id, "stat" => "strength", "action" => "punch", "target_id" => 99_999 },
        context
      )
      expect(out["error"]).to match(/no character/)
    end

    it "rejects invalid difficulty" do
      out = described_class.new.call(
        { "actor_id" => player.id, "stat" => "strength", "action" => "x", "difficulty" => "trivial_plus" },
        context
      )
      expect(out["error"]).to match(/difficulty must be one of/)
    end

    it "rejects item not in actor's inventory" do
      sword = Item.create!(name: "Sword", subrole: "weapon", character: bandit)
      out = described_class.new.call(
        { "actor_id" => player.id, "stat" => "strength", "action" => "swing", "item_id" => sword.id },
        context
      )
      expect(out["error"]).to match(/not in actor's inventory/)
    end
  end

  describe "effect application (buff / heal / debuff)" do
    let(:bless) {
      { "id" => "bless", "name" => "Bless", "effect_kind" => "buff", "stat" => "wisdom",
        "uses_per_rest" => 3, "uses_remaining" => 3,
        "effect" => { "duration_minutes" => 30, "roll_modifier" => 2 } }
    }
    let(:mend) {
      { "id" => "mend", "name" => "Mend", "effect_kind" => "heal", "stat" => "wisdom",
        "damage_dice" => "1d8", "uses_per_rest" => 4, "uses_remaining" => 4 }
    }

    it "auto-succeeds a self-buff without rolling, applies the timed effect, pays no XP" do
      player.update!(wisdom: 10, abilities: [ bless ])
      expect(::Harness::Dice).not_to receive(:check)

      out = described_class.new.call({ "actor_id" => player.id, "ability_name" => "Bless", "action" => "casts bless" }, context)

      expect(out["outcome"]).to eq("success")
      expect(out["effect_applied"]).to include("name" => "Bless", "on" => player.name)
      expect(out["xp_gained"]).to be_nil
      expect(Harness::Character::ActiveEffects.roll_modifier(player.reload, now: context.game_time)).to eq(2)
      expect(player.abilities.first["uses_remaining"]).to eq(2) # cast spent a use
    end

    it "heals rolled HP capped at max, no dice check, no XP" do
      player.update!(wisdom: 10, max_hp: 20, current_hp: 12, abilities: [ mend ])
      allow(Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(30)
      expect(::Harness::Dice).not_to receive(:check)

      out = described_class.new.call({ "actor_id" => player.id, "ability_name" => "Mend", "action" => "mends wounds" }, context)

      expect(out["healed"]).to eq(8) # capped at max_hp
      expect(player.reload.current_hp).to eq(20)
      expect(out["xp_gained"]).to be_nil
    end

    it "a live Bless adds its flat roll modifier to the caster's later checks" do
      player.update!(wisdom: 10, abilities: [ bless ])
      described_class.new.call({ "actor_id" => player.id, "ability_name" => "Bless", "action" => "casts bless" }, context)

      expect(::Harness::Dice).to receive(:check).with(hash_including(roll_modifier: 2))
        .and_return(::Harness::Dice::Outcome.new(result: "failure", margin: "narrow", critical: false))
      described_class.new.call({ "actor_id" => player.id, "stat" => "strength", "action" => "force the door", "difficulty" => "hard" }, context)
    end

    it "a debuff rolls opposed and lands its effect on the TARGET" do
      player.update!(charisma: 14, abilities: [
        { "id" => "dread_aura", "name" => "Dread Aura", "effect_kind" => "debuff", "stat" => "charisma",
          "opposed_by" => "wisdom", "uses_per_rest" => 2, "uses_remaining" => 2,
          "effect" => { "duration_minutes" => 30, "roll_modifier" => -2 } }
      ])
      stub_dice_outcome(result: "success")

      out = described_class.new.call(
        { "actor_id" => player.id, "ability_name" => "Dread Aura", "action" => "radiates dread", "target_id" => bandit.id },
        context
      )

      expect(out["effect_applied"]).to include("name" => "Dread Aura", "on" => bandit.name)
      expect(Harness::Character::ActiveEffects.roll_modifier(bandit.reload, now: context.game_time)).to eq(-2)
    end
  end

  describe "check XP (non-combat)" do
    def check(args = {})
      described_class.new.call(
        { "actor_id" => player.id, "stat" => "dexterity", "action" => "scale the wall" }.merge(args),
        context
      )
    end

    it "awards difficulty-tier XP to the player on a successful check" do
      stub_dice_outcome(result: "success")
      out = check("difficulty" => "hard")
      expect(out["xp_gained"]).to eq(15)
      expect(player.reload.xp).to eq(15)
    end

    it "pays the clever bonus from the positive situational modifier" do
      stub_dice_outcome(result: "success")
      out = check("difficulty" => "hard", "roll_modifier" => 3)
      expect(out["xp_gained"]).to eq(15 + 9)
    end

    it "pays nothing for easy tiers or on failure" do
      stub_dice_outcome(result: "success")
      expect(check("difficulty" => "easy")["xp_gained"]).to be_nil

      stub_dice_outcome(result: "failure")
      expect(check("difficulty" => "hard")["xp_gained"]).to be_nil
      expect(player.reload.xp).to eq(0)
    end

    it "pays the opposed rate for beating a live opponent's roll" do
      stub_dice_outcome(result: "success")
      out = check("stat" => "charisma", "action" => "stare him down",
                  "target_id" => bandit.id, "target_stat" => "wisdom")
      expect(out["xp_gained"]).to eq(15)
    end

    it "never awards check XP to an NPC actor" do
      stub_dice_outcome(result: "success")
      out = check("actor_id" => bandit.id, "difficulty" => "hard")
      expect(out["xp_gained"]).to be_nil
      expect(bandit.reload.xp.to_i).to eq(0)
    end
  end

  describe "unopposed check" do
    it "returns the outcome tier and margin from Dice" do
      stub_dice_outcome(result: "success", margin: "clear")
      out = described_class.new.call(
        { "actor_id" => player.id, "stat" => "dexterity", "action" => "balance on the rope", "difficulty" => "hard" },
        context
      )
      expect(out["outcome"]).to eq("success")
      expect(out["margin"]).to eq("clear")
      expect(out["critical"]).to be(false)
      expect(out["actor_id"]).to eq(player.id)
      expect(out["target_id"]).to be_nil
    end

    it "defaults difficulty to 'moderate' when omitted" do
      expect(::Harness::Dice).to receive(:check).with(hash_including(difficulty: "moderate"))
        .and_return(::Harness::Dice::Outcome.new(result: "failure", margin: "narrow", critical: false))
      described_class.new.call(
        { "actor_id" => player.id, "stat" => "wisdom", "action" => "notice trap" },
        context
      )
    end

    it "returns LLM no dice numbers or stat values" do
      stub_dice_outcome(result: "success", margin: "clear")
      out = described_class.new.call(
        { "actor_id" => player.id, "stat" => "strength", "action" => "shove" },
        context
      )
      expect(out).not_to have_key("roll")
      expect(out).not_to have_key("stat_value")
      expect(out).not_to have_key("dc")
    end

    it "surfaces the stat actually rolled in the result (narration uses this verbatim)" do
      stub_dice_outcome(result: "success", margin: "narrow")
      out = described_class.new.call(
        { "actor_id" => player.id, "stat" => "wisdom", "action" => "notice trap" },
        context
      )
      # Critical: narration must NOT guess; resolve hands it the exact stat.
      expect(out["stat"]).to eq("wisdom")
    end
  end

  describe "opposed check" do
    it "passes actor and target stat values to Dice" do
      expect(::Harness::Dice).to receive(:check).with(
        hash_including(actor_stat: 14, target_stat: 10)
      ).and_return(::Harness::Dice::Outcome.new(result: "success", margin: "narrow", critical: false))

      described_class.new.call(
        { "actor_id" => player.id, "stat" => "strength", "action" => "grapple", "target_id" => bandit.id },
        context
      )
    end

    it "uses target_stat when given, otherwise echoes stat" do
      expect(::Harness::Dice).to receive(:check).with(
        hash_including(actor_stat: 10, target_stat: 8)
      ).and_return(::Harness::Dice::Outcome.new(result: "failure", margin: "narrow", critical: false))

      described_class.new.call(
        { "actor_id" => player.id, "stat" => "charisma", "action" => "persuade", "target_id" => bandit.id, "target_stat" => "wisdom" },
        context
      )
    end

    it "returns target_id in the result" do
      stub_dice_outcome(result: "success", margin: "decisive")
      out = described_class.new.call(
        { "actor_id" => player.id, "stat" => "strength", "action" => "shove", "target_id" => bandit.id },
        context
      )
      expect(out["target_id"]).to eq(bandit.id)
    end
  end

  describe "item modifier" do
    it "applies item.properties.roll_modifier" do
      amulet = Item.create!(name: "Amulet of Speech", subrole: "trinket", character: player, properties: { "roll_modifier" => 2 })
      expect(::Harness::Dice).to receive(:check).with(
        hash_including(roll_modifier: 2)
      ).and_return(::Harness::Dice::Outcome.new(result: "success", margin: "narrow", critical: false))

      described_class.new.call(
        { "actor_id" => player.id, "stat" => "charisma", "action" => "sweet-talk", "item_id" => amulet.id },
        context
      )
    end

    it "treats missing roll_modifier as 0" do
      plain = Item.create!(name: "Stick", subrole: "tool", character: player)
      expect(::Harness::Dice).to receive(:check).with(
        hash_including(roll_modifier: 0)
      ).and_return(::Harness::Dice::Outcome.new(result: "failure", margin: "narrow", critical: false))

      described_class.new.call(
        { "actor_id" => player.id, "stat" => "strength", "action" => "swing", "item_id" => plain.id },
        context
      )
    end
  end

  describe "tactical roll_modifier (LLM-supplied)" do
    it "passes the situational modifier through to Dice.check and surfaces it on the outcome" do
      expect(::Harness::Dice).to receive(:check).with(
        hash_including(roll_modifier: 3)
      ).and_return(::Harness::Dice::Outcome.new(result: "success", margin: "clear", critical: false))

      out = described_class.new.call(
        { "actor_id" => player.id, "stat" => "dexterity", "action" => "surprise strike", "roll_modifier" => 3 },
        context
      )
      expect(out["roll_modifier"]).to eq(3)
    end

    it "sums situational modifier with item modifier" do
      amulet = Item.create!(name: "Amulet", character: player, properties: { "roll_modifier" => 2 })
      expect(::Harness::Dice).to receive(:check).with(
        hash_including(roll_modifier: 5)  # 2 (item) + 3 (situational)
      ).and_return(::Harness::Dice::Outcome.new(result: "success", margin: "narrow", critical: false))

      described_class.new.call(
        { "actor_id" => player.id, "stat" => "charisma", "action" => "press", "item_id" => amulet.id, "roll_modifier" => 3 },
        context
      )
    end

    it "clamps the situational modifier to [-5, +5]" do
      expect(::Harness::Dice).to receive(:check).with(
        hash_including(roll_modifier: 5)
      ).and_return(::Harness::Dice::Outcome.new(result: "success", margin: "decisive", critical: false))

      described_class.new.call(
        { "actor_id" => player.id, "stat" => "strength", "action" => "wild swing", "roll_modifier" => 999 },
        context
      )
    end

    it "clamps negative modifiers symmetrically" do
      expect(::Harness::Dice).to receive(:check).with(
        hash_including(roll_modifier: -5)
      ).and_return(::Harness::Dice::Outcome.new(result: "failure", margin: "narrow", critical: false))

      described_class.new.call(
        { "actor_id" => player.id, "stat" => "dexterity", "action" => "tripped move", "roll_modifier" => -50 },
        context
      )
    end

    it "ignores non-integer roll_modifier" do
      expect(::Harness::Dice).to receive(:check).with(
        hash_including(roll_modifier: 0)
      ).and_return(::Harness::Dice::Outcome.new(result: "success", margin: "narrow", critical: false))

      described_class.new.call(
        { "actor_id" => player.id, "stat" => "wisdom", "action" => "perceive", "roll_modifier" => "lots" },
        context
      )
    end

    it "omits roll_modifier from outcome when zero" do
      allow(::Harness::Dice).to receive(:check).and_return(::Harness::Dice::Outcome.new(result: "success", margin: "narrow", critical: false))
      out = described_class.new.call(
        { "actor_id" => player.id, "stat" => "wisdom", "action" => "look around" },
        context
      )
      expect(out).not_to have_key("roll_modifier")
    end
  end

  describe "side effects" do
    it "advances context.game_time by 1" do
      stub_dice_outcome(result: "success", margin: "narrow")
      expect {
        described_class.new.call(
          { "actor_id" => player.id, "stat" => "strength", "action" => "shove" },
          context
        )
      }.to change { context.game_time }.from(100).to(101)
    end

    it "forward-appends a personal-scope event with actor as participant" do
      stub_dice_outcome(result: "success", margin: "narrow")
      expect {
        described_class.new.call(
          { "actor_id" => player.id, "stat" => "strength", "action" => "shove" },
          context
        )
      }.to change(Event, :count).by(1)

      ev = Event.last
      expect(ev.scope).to eq("personal")
      expect(ev.game_time).to eq(101)
      expect(ev.location).to eq(tavern)
      expect(ev.details["resolve"]).to include("action" => "shove", "stat" => "strength", "outcome" => "success")
      expect(ev.event_participants.first.character).to eq(player)
      expect(ev.event_participants.first.role).to eq("actor")
    end

    it "includes target as participant in opposed checks" do
      stub_dice_outcome(result: "success", margin: "narrow")
      described_class.new.call(
        { "actor_id" => player.id, "stat" => "strength", "action" => "grapple", "target_id" => bandit.id },
        context
      )
      ev = Event.last
      roles = ev.event_participants.map(&:role)
      expect(roles).to contain_exactly("actor", "target")
    end
  end

  describe "stats materialization" do
    it "materializes the target's stats if any are nil, using context.llm_client" do
      unstatted = Npc.create!(name: "Patron", subrole: "drunk", location: tavern)
      context.llm_client = StubLLM.new { |_prompt|
        Character::STATS.each_with_object({ "level" => 1, "character_class" => "commoner" }) { |s, h| h[s] = 10 }.to_json
      }
      stub_dice_outcome(result: "success", margin: "narrow")

      described_class.new.call(
        { "actor_id" => player.id, "stat" => "strength", "action" => "shove", "target_id" => unstatted.id },
        context
      )
      expect(unstatted.reload.strength).to eq(10)
    end

    it "skips materialization gracefully when llm_client is absent" do
      unstatted = Npc.create!(name: "Patron", subrole: "drunk", location: tavern)
      context.llm_client = nil
      stub_dice_outcome(result: "success", margin: "narrow")

      expect {
        described_class.new.call(
          { "actor_id" => player.id, "stat" => "strength", "action" => "shove", "target_id" => unstatted.id },
          context
        )
      }.not_to raise_error
      # Stat remains nil; Character#stat falls back to default 10 inside the tool.
      expect(unstatted.reload.strength).to be_nil
    end
  end

  describe "items integration" do
    let(:player_with_ability) {
      Player.create!(
        name: "Hero", location: tavern,
        strength: 12, dexterity: 12, constitution: 12, intelligence: 10, wisdom: 10, charisma: 10,
        character_class: "fighter", level: 3, current_hp: 20, max_hp: 20,
        abilities: [
          {
            "name"           => "Heavy Strike",
            "id"             => "heavy_strike",
            "effect_kind"    => "damage",
            "damage_dice"    => "1d4",
            "damage_per_level" => nil,
            "stat"           => "strength",
            "opposed_by"     => "dexterity",
            "uses_per_rest"  => 4,
            "uses_remaining" => 4,
            "tags"           => [ "martial", "weapon" ],
            "requires_tags"  => [ "weapon" ]
          }
        ]
      )
    }

    let(:doomed_target) {
      Npc.create!(
        name: "Lookout", subrole: "bandit", location: tavern,
        strength: 8, dexterity: 8, constitution: 8, intelligence: 8, wisdom: 8, charisma: 8,
        current_hp: 3, max_hp: 12, character_class: "fighter", level: 1
      )
    }

    describe "stat bonus from owned items" do
      it "boosts the actor's effective stat for the dice check" do
        Item.create!(
          name: "rusted dagger", character_id: player.id,
          properties: { "tags" => [ "weapon" ], "modifiers" => [ { "stat" => "strength", "op" => "add", "value" => 3 } ], "effects" => [] }
        )

        captured_stat = nil
        allow(::Harness::Dice).to receive(:check) { |actor_stat:, **|
          captured_stat = actor_stat
          ::Harness::Dice::Outcome.new(result: "success", margin: "narrow", critical: false)
        }

        described_class.new.call(
          { "actor_id" => player.id, "stat" => "strength", "action" => "shove", "target_id" => bandit.id },
          context
        )
        # player.strength = 14; +3 from item = 17.
        expect(captured_stat).to eq(17)
      end
    end

    describe "tag gating + unarmed_strike fallback" do
      it "blocks an ability that requires a tag the actor's items don't supply" do
        out = described_class.new.call(
          { "actor_id" => player_with_ability.id, "ability_name" => "Heavy Strike", "action" => "swing", "target_id" => bandit.id },
          context
        )
        expect(out["error"]).to match(/requires item tags=\["weapon"\]/)
        expect(out["error"]).to include("unarmed_strike")
      end

      it "passes the gate when the actor owns an item with the required tag" do
        Item.create!(
          name: "plain longsword", character_id: player_with_ability.id,
          properties: { "tags" => [ "weapon" ], "modifiers" => [], "effects" => [] }
        )
        stub_dice_outcome(result: "success", margin: "narrow")

        out = described_class.new.call(
          { "actor_id" => player_with_ability.id, "ability_name" => "Heavy Strike", "action" => "swing", "target_id" => bandit.id },
          context
        )
        expect(out["error"]).to be_nil
        expect(out["outcome"]).to eq("success")
      end

      it "unarmed_strike works without any items, deals 1d4 damage, doesn't spend an ability use" do
        stub_dice_outcome(result: "success", margin: "narrow")

        out = described_class.new.call(
          { "actor_id" => player_with_ability.id, "ability_name" => "unarmed_strike", "action" => "punch", "target_id" => doomed_target.id },
          context
        )
        expect(out["error"]).to be_nil
        expect(out["damage"]).to be_between(1, 4)
        # Ability use NOT spent (unarmed has no library entry).
        expect(player_with_ability.reload.abilities.first["uses_remaining"]).to eq(4)
      end
    end

    describe "death_save trigger on lethal damage" do
      it "clamps target HP to 1 instead of zero, destroys the amulet" do
        amulet = Item.create!(
          name: "Amulet of the Drowned Saint", character_id: doomed_target.id,
          properties: { "tags" => [ "magical" ], "modifiers" => [],
                        "effects" => [ { "trigger" => "death_save", "params" => { "hp_after" => 1, "destroy_on_use" => true } } ] }
        )
        # Force lethal damage. Stub both the dice tier (crit) and the
        # damage roll — Heavy Strike's 1d4 is otherwise unstubbed and on
        # a roll of 1 (×2 crit = 2) doesn't exceed doomed_target's 3 HP,
        # which would skip on_lethal entirely.
        stub_dice_outcome(result: "critical_success", margin: "decisive", critical: true)
        allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(5)
        # Equip the player with a weapon so the gate passes.
        Item.create!(name: "blade", character_id: player_with_ability.id,
                     properties: { "tags" => [ "weapon" ], "modifiers" => [], "effects" => [] })

        out = described_class.new.call(
          { "actor_id" => player_with_ability.id, "ability_name" => "Heavy Strike", "action" => "swing", "target_id" => doomed_target.id },
          context
        )

        doomed_target.reload
        expect(doomed_target.current_hp).to eq(1)
        expect(doomed_target.properties["stance"]).not_to eq("downed")
        expect(Item.find_by(id: amulet.id)).to be_nil
        expect(out["target_downed"]).to be(false)
      end
    end

    describe "loot drop on kill" do
      it "anchors the deceased's items to the location and surfaces them on the outcome" do
        coin_purse = Item.create!(name: "tarnished ring", character_id: doomed_target.id,
                                  properties: { "tags" => [ "jewelry" ], "modifiers" => [], "effects" => [] })
        weapon     = Item.create!(name: "rusty knife",   character_id: doomed_target.id,
                                  properties: { "tags" => [ "weapon" ],  "modifiers" => [], "effects" => [] })
        doomed_target.update!(coins: 8)
        Item.create!(name: "blade", character_id: player_with_ability.id,
                     properties: { "tags" => [ "weapon" ], "modifiers" => [], "effects" => [] })

        stub_dice_outcome(result: "critical_success", margin: "decisive", critical: true)
        allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(50)

        out = described_class.new.call(
          { "actor_id" => player_with_ability.id, "ability_name" => "Heavy Strike", "action" => "swing", "target_id" => doomed_target.id },
          context
        )

        expect(doomed_target.reload.current_hp).to eq(0)
        # Items detached from corpse, anchored to location.
        [ coin_purse, weapon ].each do |it|
          it.reload
          expect(it.character_id).to be_nil
          expect(it.location_id).to eq(doomed_target.location_id)
        end
        # Outcome surfaces what dropped + how many coins are still on the corpse.
        expect(out["dropped_items"].map { |i| i["id"] }.sort).to eq([ coin_purse.id, weapon.id ].sort)
        expect(out["looted_coins"]).to eq(8)
        # Coins do NOT auto-transfer; they sit on the corpse waiting for transfer_coins.
        expect(doomed_target.reload.coins).to eq(8)
      end

      it "does not drop items when the target survives the hit" do
        Item.create!(name: "knife", character_id: doomed_target.id, properties: {})
        Item.create!(name: "blade", character_id: player_with_ability.id,
                     properties: { "tags" => [ "weapon" ] })
        stub_dice_outcome(result: "success", margin: "narrow", critical: false)
        allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(1)

        out = described_class.new.call(
          { "actor_id" => player_with_ability.id, "ability_name" => "Heavy Strike", "action" => "swing", "target_id" => doomed_target.id },
          context
        )

        expect(doomed_target.reload.current_hp).to be > 0
        expect(out["dropped_items"]).to be_nil
        expect(out["looted_coins"]).to be_nil
        expect(::Item.where(character_id: doomed_target.id).count).to eq(1)
      end
    end

    describe "damage_resist trigger" do
      it "reduces incoming damage by params[:amount]" do
        Item.create!(
          name: "ringmail", character_id: doomed_target.id,
          properties: { "tags" => [ "armor" ], "modifiers" => [],
                        "effects" => [ { "trigger" => "damage_resist", "params" => { "amount" => 5, "type" => nil } } ] }
        )
        Item.create!(name: "blade", character_id: player_with_ability.id,
                     properties: { "tags" => [ "weapon" ], "modifiers" => [], "effects" => [] })

        stub_dice_outcome(result: "success", margin: "narrow", critical: false)
        # Heavy Strike rolls 1d4 (damage_dice). Force into a known range by
        # observing damage in the outcome — should be reduced by 5 (likely 0).
        out = described_class.new.call(
          { "actor_id" => player_with_ability.id, "ability_name" => "Heavy Strike", "action" => "swing", "target_id" => doomed_target.id },
          context
        )
        # 1d4 (max 4) minus 5 resist = 0. Target should still have 3 HP.
        expect(doomed_target.reload.current_hp).to eq(3)
      end
    end
  end

  describe "dead target rejection" do
    let(:corpse) {
      Npc.create!(
        name: "Cadaver", subrole: "bandit", location: tavern,
        strength: 10, dexterity: 10, constitution: 10,
        intelligence: 8, wisdom: 8, charisma: 6,
        current_hp: 0, max_hp: 12
      )
    }

    it "returns a structural error and does not roll dice when target is at 0 HP" do
      expect(::Harness::Dice).not_to receive(:check)
      out = described_class.new.call(
        { "actor_id" => player.id, "stat" => "strength", "action" => "swing", "target_id" => corpse.id },
        context
      )
      expect(out["error"]).to match(/already dead/)
    end

    it "does not advance the clock when rejecting a dead target" do
      before_time = context.game_time
      described_class.new.call(
        { "actor_id" => player.id, "stat" => "strength", "action" => "swing", "target_id" => corpse.id },
        context
      )
      expect(context.game_time).to eq(before_time)
    end
  end

  describe "follower flag clear on death" do
    let(:follower) {
      Npc.create!(
        name: "Ally", subrole: "fighter", location: tavern,
        strength: 8, dexterity: 8, constitution: 8, intelligence: 8, wisdom: 8, charisma: 8,
        current_hp: 1, max_hp: 12, character_class: "fighter", level: 1,
        properties: { "following_player" => true, "personality" => "loyal" }
      )
    }
    let(:player_with_ability) {
      Player.create!(
        name: "Hero", location: tavern,
        strength: 12, dexterity: 12, constitution: 12, intelligence: 10, wisdom: 10, charisma: 10,
        character_class: "fighter", level: 3, current_hp: 20, max_hp: 20,
        abilities: [
          {
            "name" => "Heavy Strike", "id" => "heavy_strike", "effect_kind" => "damage",
            "damage_dice" => "1d4", "damage_per_level" => nil,
            "stat" => "strength", "opposed_by" => "dexterity",
            "uses_per_rest" => 4, "uses_remaining" => 4,
            "tags" => [ "martial", "weapon" ], "requires_tags" => [ "weapon" ]
          }
        ]
      )
    }

    it "strips following_player when the kill drops the target to 0 HP" do
      Item.create!(name: "blade", character_id: player_with_ability.id,
                   properties: { "tags" => [ "weapon" ], "modifiers" => [], "effects" => [] })
      stub_dice_outcome(result: "critical_success", margin: "decisive", critical: true)
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(50)

      described_class.new.call(
        { "actor_id" => player_with_ability.id, "ability_name" => "Heavy Strike", "action" => "betray", "target_id" => follower.id },
        context
      )

      follower.reload
      expect(follower.current_hp).to eq(0)
      expect(follower.properties).not_to have_key("following_player")
      # Other properties survive — we only stripped the one key.
      expect(follower.properties["personality"]).to eq("loyal")
    end

    it "leaves following_player intact when the target survives the hit" do
      Item.create!(name: "blade", character_id: player_with_ability.id,
                   properties: { "tags" => [ "weapon" ], "modifiers" => [], "effects" => [] })
      follower.update!(current_hp: 20)  # ample HP
      stub_dice_outcome(result: "success", margin: "narrow", critical: false)
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(1)

      described_class.new.call(
        { "actor_id" => player_with_ability.id, "ability_name" => "Heavy Strike", "action" => "graze", "target_id" => follower.id },
        context
      )

      follower.reload
      expect(follower.current_hp).to be > 0
      expect(follower.properties["following_player"]).to be(true)
    end
  end

  describe "combat-mode range gate" do
    let(:scene) {
      Harness::Scene::Assembler # force-load Snapshot
      snap = Harness::Scene::Snapshot.new(location: tavern, present_characters: [ player, bandit ], present_corpses: [], present_items: [])
      Harness::Scene::Active.new(
        location: tavern, snapshot: snap, narrations: [], internal_state: {}, agendas: {},
        extras: [], entered_at_game_time: 0
      )
    }
    let(:combat_context) {
      ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100)
      ctx.active_scene = scene
      scene.start_combat!
      scene.combat.add_combatant(player.id, side: "player_party")
      scene.combat.add_combatant(bandit.id, side: "marauders")
      ctx
    }

    let(:player_with_close_ability) {
      player.update!(abilities: [ {
        "name" => "Heavy Strike", "stat" => "strength", "opposed_by" => "dexterity",
        "effect_kind" => "damage", "damage_dice" => "1d8", "uses_remaining" => 3,
        "tags" => [ "martial" ], "requires_tags" => [], "range" => "close"
      } ])
      player
    }
    let(:player_with_near_ability) {
      player.update!(abilities: [ {
        "name" => "Charm Word", "stat" => "charisma", "opposed_by" => "wisdom",
        "effect_kind" => "control", "uses_remaining" => 2,
        "tags" => [ "social" ], "requires_tags" => [], "range" => "near"
      } ])
      player
    }
    let(:player_with_far_ability) {
      player.update!(abilities: [ {
        "name" => "Spark", "stat" => "intelligence", "opposed_by" => "dexterity",
        "effect_kind" => "damage", "damage_dice" => "1d6", "uses_remaining" => 3,
        "tags" => [ "arcane" ], "requires_tags" => [], "range" => "far"
      } ])
      player
    }

    it "rejects close ability when actor is not engaged with target" do
      player_with_close_ability
      combat_context.active_scene.combat.set_position!(player.id, "near")
      combat_context.active_scene.combat.set_position!(bandit.id, "near")
      out = described_class.new.call(
        { "actor_id" => player.id, "ability_name" => "Heavy Strike", "action" => "swing", "target_id" => bandit.id },
        combat_context
      )
      expect(out["error"]).to match(/melee range/)
    end

    it "rejects close ability when actor and target are engaged with DIFFERENT opponents" do
      player_with_close_ability
      other = Npc.create!(name: "Other", subrole: "marauder", location: tavern, strength: 10, dexterity: 10)
      combat_context.active_scene.combat.add_combatant(other.id, side: "marauders")
      combat_context.active_scene.combat.engage!(player.id, other.id)
      combat_context.active_scene.combat.set_position!(bandit.id, "engaged")
      out = described_class.new.call(
        { "actor_id" => player.id, "ability_name" => "Heavy Strike", "action" => "swing", "target_id" => bandit.id },
        combat_context
      )
      expect(out["error"]).to match(/melee range/)
    end

    it "allows close ability when actor and target are engaged with each other" do
      player_with_close_ability
      combat_context.active_scene.combat.engage!(player.id, bandit.id)
      stub_dice_outcome(result: "success", margin: "clear", critical: false)
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(4)
      out = described_class.new.call(
        { "actor_id" => player.id, "ability_name" => "Heavy Strike", "action" => "strike", "target_id" => bandit.id },
        combat_context
      )
      expect(out["error"]).to be_nil
    end

    it "disengages a killed target so survivors don't carry stale engagement edges" do
      player_with_close_ability
      combat_context.active_scene.combat.engage!(player.id, bandit.id)
      stub_dice_outcome(result: "critical_success", margin: "decisive", critical: true)
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(50)

      out = described_class.new.call(
        { "actor_id" => player.id, "ability_name" => "Heavy Strike", "action" => "kill", "target_id" => bandit.id },
        combat_context
      )
      expect(out["error"]).to be_nil
      bandit.reload
      expect(bandit.current_hp).to eq(0)
      state = combat_context.active_scene.combat
      # Player's engagement edge cleared.
      expect(state.engaged_with_of(player.id)).to be_nil
      expect(state.engaged_with_of(bandit.id)).to be_nil
      # But the dead character is still in sides / initiative — Loop's
      # dead-actor skip handles their slot; removing mid-round corrupts
      # the initiative_index.
      expect(state.combatant?(bandit.id)).to be(true)
    end

    it "rejects near ability when target is at far range" do
      player_with_near_ability
      combat_context.active_scene.combat.set_position!(bandit.id, "far")
      out = described_class.new.call(
        { "actor_id" => player.id, "ability_name" => "Charm Word", "action" => "cajole", "target_id" => bandit.id },
        combat_context
      )
      expect(out["error"]).to match(/cannot reach far targets/)
    end

    it "allows near ability when target is at near range" do
      player_with_near_ability
      combat_context.active_scene.combat.set_position!(bandit.id, "near")
      stub_dice_outcome(result: "success", margin: "clear", critical: false)
      out = described_class.new.call(
        { "actor_id" => player.id, "ability_name" => "Charm Word", "action" => "cajole", "target_id" => bandit.id },
        combat_context
      )
      expect(out["error"]).to be_nil
    end

    it "allows far ability against any range" do
      player_with_far_ability
      combat_context.active_scene.combat.set_position!(bandit.id, "far")
      stub_dice_outcome(result: "success", margin: "clear", critical: false)
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(3)
      out = described_class.new.call(
        { "actor_id" => player.id, "ability_name" => "Spark", "action" => "hurl", "target_id" => bandit.id },
        combat_context
      )
      expect(out["error"]).to be_nil
    end

    it "stat-only resolves bypass the range gate" do
      combat_context.active_scene.combat.set_position!(bandit.id, "far")
      stub_dice_outcome(result: "success", margin: "clear", critical: false)
      out = described_class.new.call(
        { "actor_id" => player.id, "stat" => "strength", "action" => "shove", "target_id" => bandit.id },
        combat_context
      )
      expect(out["error"]).to be_nil
    end

    it "non-combat scene bypasses the range gate even with abilities" do
      player_with_close_ability
      ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100)
      ctx.active_scene = scene  # NOT in combat
      stub_dice_outcome(result: "success", margin: "clear", critical: false)
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(4)
      out = described_class.new.call(
        { "actor_id" => player.id, "ability_name" => "Heavy Strike", "action" => "strike", "target_id" => bandit.id },
        ctx
      )
      expect(out["error"]).to be_nil
    end
  end

  describe "watcher-attacked transition" do
    let(:barkeep) {
      Npc.create!(name: "Maren", subrole: "barkeep", location: tavern,
                  strength: 12, dexterity: 10, constitution: 12, intelligence: 10, wisdom: 12, charisma: 10,
                  current_hp: 16, max_hp: 16)
    }
    let(:scene) {
      Harness::Scene::Assembler
      snap = Harness::Scene::Snapshot.new(location: tavern, present_characters: [ player, bandit, barkeep ], present_corpses: [], present_items: [])
      Harness::Scene::Active.new(location: tavern, snapshot: snap, narrations: [], internal_state: {}, agendas: {},
                                 extras: [], entered_at_game_time: 0)
    }
    let(:combat_context) {
      ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100)
      ctx.active_scene = scene
      scene.start_combat!
      scene.combat.add_combatant(player.id, side: "player_party")
      scene.combat.add_combatant(bandit.id, side: "marauders")
      scene.combat.add_watcher(barkeep.id)
      scene.combat.initiative = [ player.id, bandit.id ]
      ctx
    }

    it "promotes a watcher to combatant on the side opposite the attacker when attacked" do
      stub_dice_outcome(result: "success", margin: "clear")
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(2)
      described_class.new.call(
        { "actor_id" => bandit.id, "stat" => "strength", "action" => "smack", "target_id" => barkeep.id },
        combat_context
      )
      state = combat_context.active_scene.combat
      expect(state.watcher?(barkeep.id)).to be(false)
      expect(state.combatant?(barkeep.id)).to be(true)
      expect(state.side_of(barkeep.id)).to eq("player_party")
    end

    it "splices the new combatant's initiative slot after the current actor" do
      stub_dice_outcome(result: "success", margin: "clear")
      allow(::Harness::Abilities::DiceFormula).to receive(:roll_ability).and_return(2)
      # Current actor is player.id (initiative_index 0). New slot should be at index 1.
      described_class.new.call(
        { "actor_id" => player.id, "stat" => "charisma", "action" => "shove", "target_id" => barkeep.id },
        combat_context
      )
      expect(combat_context.active_scene.combat.initiative).to eq([ player.id, barkeep.id, bandit.id ])
    end
  end
end
