require "rails_helper"

RSpec.describe Harness::Runners::Environment do
  let(:loc) { Location.create!(name: "Clearing") }
  let!(:player) {
    Player.create!(name: "Hero", location: loc, charisma: 14,
                   abilities: [ { "name" => "Wild Surge", "stat" => "charisma", "uses_remaining" => 3 } ])
  }
  let(:step) { Harness::Dispatcher::Step.new(runner: "environment", intent: "act on an object", args: {}) }

  def ctx_emitting(payload)
    json = payload.is_a?(String) ? payload : payload.to_json
    Harness::Turn::Context.new(player_location: loc, llm_nuance: StubLLM.new { json }, game_time: 100)
  end

  def run(ctx, input)
    described_class.new.run(context: ctx, scene: nil, input: input, step: step)
  end

  def names(out) = out.tool_calls.map { |t| t["name"] }

  it "pure flavor (all null) emits nothing but succeeds — no delta, no fragment" do
    out = run(ctx_emitting("action" => "kick the locked gate", "roll" => nil, "yields_item" => nil, "location_change" => nil), "kick the gate")
    expect(out.status).to eq(:ok)
    expect(out.tool_calls).to be_empty
    # Mini-narrator: carries its null explanation for the display floor
    # (rendered only if the whole turn ends empty).
    expect(out.null_line).to eq("Nothing comes of it — kick the locked gate.")
  end

  it "renders its own fragment after committing a delta" do
    ctx = Harness::Turn::Context.new(player_location: loc, game_time: 100,
      llm_nuance: StubLLM.new { |full|
        full.include?("render ONE physical act") ? "The branches snap clean." :
          { "action" => "snap dry branches", "roll" => nil,
            "yields_item" => { "name" => "bundle of firewood", "subrole" => "firewood" }, "location_change" => nil }.to_json
      })
    out = run(ctx, "gather firewood")
    frag = out.tool_calls.last
    expect(frag["name"]).to eq("display_fragment")
    expect(frag.dig("args", "text")).to eq("The branches snap clean.")
  end

  it "spawns a collectible item straight into the player's hands" do
    out = run(ctx_emitting(
      "action" => "snap dry branches", "roll" => nil,
      "yields_item" => { "name" => "bundle of firewood", "subrole" => "firewood" }, "location_change" => nil
    ), "gather firewood")
    item_tc = out.tool_calls.find { |t| t["name"] == "propose_item" }
    expect(item_tc).to be_present
    expect(item_tc.dig("args", "character_id")).to eq(player.id)
    expect(Item.where(character_id: player.id, name: "bundle of firewood")).to be_present
  end

  it "rolls an uncertain act, then yields the item on SUCCESS" do
    allow(Harness::Dice).to receive(:check).and_return(
      Harness::Dice::Outcome.new(result: "success", margin: "clear", critical: false)
    )
    out = run(ctx_emitting(
      "action" => "blast the tree apart", "time_minutes" => 2,
      "roll" => { "ability_name" => "Wild Surge", "difficulty" => "moderate" },
      "yields_item" => { "name" => "splintered wood", "subrole" => "firewood" }
    ), "blast the tree")
    expect(names(out)).to include("resolve", "propose_item")
  end

  it "WITHHOLDS the item (and any change) when the roll FAILS" do
    allow(Harness::Dice).to receive(:check).and_return(
      Harness::Dice::Outcome.new(result: "failure", margin: "narrow", critical: false)
    )
    out = run(ctx_emitting(
      "action" => "blast the tree apart",
      "roll" => { "ability_name" => "Wild Surge", "difficulty" => "moderate" },
      "yields_item" => { "name" => "splintered wood", "subrole" => "firewood" },
      "location_change" => "the tree is reduced to a stump"
    ), "blast the tree")
    expect(names(out)).to include("resolve")
    expect(names(out)).not_to include("propose_item", "mutate_location")
  end

  it "commits the pre-declared BOTCH mark (and only that) on a critical failure" do
    allow(Harness::Dice).to receive(:check).and_return(
      Harness::Dice::Outcome.new(result: "critical_failure", margin: "decisive", critical: true)
    )
    out = run(ctx_emitting(
      "action" => "force the mill mechanism",
      "roll" => { "ability_name" => "Wild Surge", "difficulty" => "moderate" },
      "yields_item" => { "name" => "loose gear", "subrole" => "salvage" },
      "location_change" => "the mechanism is realigned and the wheel turns freely",
      "location_change_on_botch" => "the gear assembly is jammed deeper into its housing"
    ), "force the mechanism")
    expect(names(out)).to include("resolve", "mutate_location")
    expect(names(out)).not_to include("propose_item")
    expect(loc.reload.properties["alterations"].join).to include("jammed deeper")
    expect(loc.properties["alterations"].join).not_to include("realigned")
  end

  it "a plain failure with a declared botch mark still commits nothing" do
    allow(Harness::Dice).to receive(:check).and_return(
      Harness::Dice::Outcome.new(result: "failure", margin: "narrow", critical: false)
    )
    out = run(ctx_emitting(
      "action" => "force the mill mechanism",
      "roll" => { "ability_name" => "Wild Surge", "difficulty" => "moderate" },
      "location_change" => "the mechanism is realigned",
      "location_change_on_botch" => "the gear assembly is jammed deeper"
    ), "force the mechanism")
    expect(names(out)).to include("resolve")
    expect(names(out)).not_to include("mutate_location")
  end

  it "transforms a held item — the same row persists with new name and kind" do
    branch = Item.create!(name: "rough branch", subrole: "object", character_id: player.id)
    out = run(ctx_emitting(
      "action" => "sharpen the branch to a point", "roll" => nil,
      "transforms_item" => { "item_id" => branch.id, "name" => "sharpened stake", "subrole" => "weapon" }
    ), "sharpen the branch")
    expect(names(out)).to include("mutate_item")
    expect(names(out)).not_to include("propose_item")
    branch.reload
    expect(branch.name).to eq("sharpened stake")
    expect(branch.subrole).to eq("weapon")
    expect(branch.character_id).to eq(player.id)
  end

  it "transforms an item anchored in the current scene" do
    plank = Item.create!(name: "warped plank", subrole: "salvage", location_id: loc.id)
    run(ctx_emitting(
      "action" => "carve the plank", "roll" => nil,
      "transforms_item" => { "item_id" => plank.id, "name" => "crude shield" }
    ), "carve the plank")
    expect(plank.reload.name).to eq("crude shield")
  end

  it "WITHHOLDS the transform when the roll FAILS" do
    branch = Item.create!(name: "rough branch", subrole: "object", character_id: player.id)
    allow(Harness::Dice).to receive(:check).and_return(
      Harness::Dice::Outcome.new(result: "failure", margin: "narrow", critical: false)
    )
    out = run(ctx_emitting(
      "action" => "sharpen the branch",
      "roll" => { "ability_name" => "Wild Surge", "difficulty" => "moderate" },
      "transforms_item" => { "item_id" => branch.id, "name" => "sharpened stake" }
    ), "sharpen the branch")
    expect(names(out)).not_to include("mutate_item")
    expect(branch.reload.name).to eq("rough branch")
  end

  it "combines: a successful transform uses up the declared component" do
    club = Item.create!(name: "driftwood club", subrole: "weapon", character_id: player.id)
    rope = Item.create!(name: "hemp rope", subrole: "cordage", character_id: player.id)
    out = run(ctx_emitting(
      "action" => "wrap the rope around the club's grip", "roll" => nil,
      "transforms_item" => { "item_id" => club.id, "name" => "rope-gripped club", "consumes_item_id" => rope.id }
    ), "wrap the club's grip")
    expect(names(out)).to include("mutate_item", "destroy_item")
    expect(club.reload.name).to eq("rope-gripped club")
    expect(Item.exists?(rope.id)).to be(false)
  end

  it "combines: a FAILED roll leaves both the item and the component untouched" do
    club = Item.create!(name: "driftwood club", subrole: "weapon", character_id: player.id)
    rope = Item.create!(name: "hemp rope", subrole: "cordage", character_id: player.id)
    allow(Harness::Dice).to receive(:check).and_return(
      Harness::Dice::Outcome.new(result: "failure", margin: "narrow", critical: false)
    )
    out = run(ctx_emitting(
      "action" => "wrap the rope around the club's grip",
      "roll" => { "ability_name" => "Wild Surge", "difficulty" => "moderate" },
      "transforms_item" => { "item_id" => club.id, "name" => "rope-gripped club", "consumes_item_id" => rope.id }
    ), "wrap the club's grip")
    expect(names(out)).not_to include("mutate_item", "destroy_item")
    expect(club.reload.name).to eq("driftwood club")
    expect(Item.exists?(rope.id)).to be(true)
  end

  it "combines: an out-of-reach component is not consumed, the transform still commits" do
    club      = Item.create!(name: "driftwood club", subrole: "weapon", character_id: player.id)
    elsewhere = Location.create!(name: "Far Shed")
    rope      = Item.create!(name: "hemp rope", subrole: "cordage", location_id: elsewhere.id)
    run(ctx_emitting(
      "action" => "wrap the rope around the club's grip", "roll" => nil,
      "transforms_item" => { "item_id" => club.id, "name" => "rope-gripped club", "consumes_item_id" => rope.id }
    ), "wrap the club's grip")
    expect(club.reload.name).to eq("rope-gripped club")
    expect(Item.exists?(rope.id)).to be(true)
  end

  it "failure hygiene: the fragment payload carries what stayed unchanged, never the margin word" do
    branch = Item.create!(name: "weathered driftwood", subrole: "object", character_id: player.id)
    allow(Harness::Dice).to receive(:check).and_return(
      Harness::Dice::Outcome.new(result: "failure", margin: "decisive", critical: false)
    )
    fragment_input = nil
    ctx = Harness::Turn::Context.new(player_location: loc, game_time: 100,
      llm_nuance: StubLLM.new { |full|
        if full.include?("render ONE physical act")
          fragment_input = full
          "The wood resists you."
        else
          { "action" => "carve the driftwood",
            "roll" => { "ability_name" => "Wild Surge", "difficulty" => "moderate" },
            "transforms_item" => { "item_id" => branch.id, "name" => "driftwood club" } }.to_json
        end
      })
    run(ctx, "carve the driftwood")
    expect(fragment_input).to include("unchanged")
    expect(fragment_input).to include("weathered driftwood")
    expect(fragment_input).not_to include("decisive")
  end

  it "DESTROYS the worked item on a critical failure — the botch has teeth" do
    buckler = Item.create!(name: "banded buckler", subrole: "shield", character_id: player.id)
    allow(Harness::Dice).to receive(:check).and_return(
      Harness::Dice::Outcome.new(result: "critical_failure", margin: "decisive", critical: true)
    )
    out = run(ctx_emitting(
      "action" => "mend the buckler's straps",
      "roll" => { "ability_name" => "Wild Surge", "difficulty" => "moderate" },
      "transforms_item" => { "item_id" => buckler.id, "name" => "mended buckler" }
    ), "mend the buckler")
    expect(names(out)).to include("destroy_item")
    expect(names(out)).not_to include("mutate_item")
    expect(Item.exists?(buckler.id)).to be(false)
  end

  it "a PLAIN failure (even decisive) leaves the worked item untouched" do
    buckler = Item.create!(name: "banded buckler", subrole: "shield", character_id: player.id)
    allow(Harness::Dice).to receive(:check).and_return(
      Harness::Dice::Outcome.new(result: "failure", margin: "decisive", critical: false)
    )
    out = run(ctx_emitting(
      "action" => "mend the buckler's straps",
      "roll" => { "ability_name" => "Wild Surge", "difficulty" => "moderate" },
      "transforms_item" => { "item_id" => buckler.id, "name" => "mended buckler" }
    ), "mend the buckler")
    expect(names(out)).not_to include("destroy_item", "mutate_item")
    expect(buckler.reload.name).to eq("banded buckler")
  end

  it "refuses to transform an item that is neither held by the player nor here" do
    elsewhere = Location.create!(name: "Far Field")
    crate = Item.create!(name: "sealed crate", subrole: "container", location_id: elsewhere.id)
    out = run(ctx_emitting(
      "action" => "carve the crate", "roll" => nil,
      "transforms_item" => { "item_id" => crate.id, "name" => "carved crate" }
    ), "carve the crate")
    expect(names(out)).not_to include("mutate_item")
    expect(crate.reload.name).to eq("sealed crate")
  end

  it "records a persistent location change via mutate_location" do
    out = run(ctx_emitting(
      "action" => "barricade the door", "roll" => nil, "yields_item" => nil,
      "location_change" => "the door is barricaded shut"
    ), "bar the door")
    expect(names(out)).to include("mutate_location")
    expect(loc.reload.properties["alterations"]).to include("the door is barricaded shut")
  end

  it "redispatches on an unparseable emit" do
    out = run(ctx_emitting("not json at all"), "do something")
    expect(out.status).to eq(:redispatch)
  end
end
