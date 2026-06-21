require "rails_helper"

# The equipment-gating contract: an ability's `requires_tags` must be backed by
# an owned item carrying those tags (enforced in resolve via
# Items::Modifiers.has_required_tags?). resolve_spec covers the enforcement
# mechanism; this spec locks the DECLARATIONS + the shield item + distribution
# that the playtest "Shield Up with no shield" bug exposed as missing.
RSpec.describe "equipment gating (requires_tags)" do
  describe "stock ability declarations" do
    def ability(id) = Harness::Abilities::Library.find(id)

    it "shield_up requires a shield" do
      expect(ability("shield_up")["requires_tags"]).to eq([ "shield" ])
    end

    it "weapon-tagged martial/divine strikes require a weapon" do
      %w[heavy_strike sweeping_blow storm_of_steel last_stand sacred_strike].each do |id|
        expect(ability(id)["requires_tags"]).to eq([ "weapon" ]), "#{id} should require [weapon]"
      end
    end

    it "non-equipment abilities stay ungated (most abilities)" do
      # A social/innate ability needs no gear — gating must stay rare.
      %w[intimidate shove arcane_bolt].each do |id|
        expect(Array(ability(id)["requires_tags"])).to be_empty, "#{id} should not be gated"
      end
    end

    it "every requires_tags in the library draws from the canonical vocabulary" do
      Harness::Abilities::Library.all.each do |a|
        Array(a["requires_tags"]).each do |t|
          expect(Harness::Items::Modifiers::EQUIPMENT_TAGS).to include(t),
            "ability #{a['id']} requires unknown equipment tag #{t.inspect}"
        end
      end
    end
  end

  describe "the shield item" do
    it "exists in the armor category with a `shield` base tag" do
      shield = Harness::Items::Library.find("shield")
      expect(shield).to be_present
      expect(shield["base_tags"]).to include("shield")
    end

    it "EQUIPMENT_TAGS carries the gating tags the fix relies on" do
      expect(Harness::Items::Modifiers::EQUIPMENT_TAGS).to include("weapon", "shield")
    end
  end

  describe "end to end: a fighter can Shield Up, an unequipped caster cannot" do
    let(:loc) { Location.create!(name: "Yard") }

    def shield_up!(player, target)
      Harness::Tools::Resolve.new.call(
        { "actor_id" => player.id, "ability_name" => "Shield Up", "action" => "raise guard",
          "difficulty" => "easy", "time_minutes" => 1 },
        Harness::Turn::Context.new(player_location: loc, game_time: 100)
      )
    end

    before do
      allow(Harness::Dice).to receive(:check).and_return(
        Harness::Dice::Outcome.new(result: "success", margin: "clear", critical: false)
      )
    end

    it "passes the gate when the actor owns a shield" do
      player = Player.create!(name: "Knight", location: loc, character_class: "fighter", constitution: 12,
                              abilities: [ { "name" => "Shield Up", "stat" => "constitution", "uses_remaining" => 3, "requires_tags" => [ "shield" ] } ])
      Item.create!(name: "round shield", subrole: "shield", character_id: player.id,
                   properties: { "tags" => [ "armor", "shield" ], "modifiers" => [], "effects" => [] })
      out = shield_up!(player, nil)
      expect(out["outcome"]).to be_present
      expect(out["error"]).to be_nil
    end

    it "is blocked when the actor has no shield" do
      player = Player.create!(name: "Hedge Mage", location: loc, character_class: "mage", constitution: 10,
                              abilities: [ { "name" => "Shield Up", "stat" => "constitution", "uses_remaining" => 3, "requires_tags" => [ "shield" ] } ])
      out = shield_up!(player, nil)
      expect(out["error"]).to match(/requires item tags=\["shield"\]/)
      expect(out["error"]).to include("unarmed_strike")
    end
  end

  describe "fighter starts with a shield (so Shield Up works from turn 1)" do
    it "hatches a shield into the fighter's starter kit" do
      loc    = Location.create!(name: "Keep")
      player = Player.create!(name: "Recruit", location: loc, character_class: "fighter")
      Harness::Items::Inventory.roll_for_player(player, rng: Random.new(1))
      tags = player.items.flat_map { |i| Array((i.properties || {})["tags"]) }
      expect(tags).to include("shield")
    end
  end
end
