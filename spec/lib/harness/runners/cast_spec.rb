require "rails_helper"

RSpec.describe Harness::Runners::Cast do
  let(:yard) { Location.create!(name: "Yard") }
  let!(:player) {
    Player.create!(
      name: "Hero", location: yard,
      strength: 10, dexterity: 10, constitution: 10, intelligence: 10, wisdom: 10, charisma: 10,
      max_hp: 20, current_hp: 20
    )
  }
  let(:bless_row) {
    { "id" => "bless", "name" => "Bless", "effect_kind" => "buff", "stat" => "wisdom",
      "description" => "The next critical effort goes better.",
      "uses_per_rest" => 3, "uses_remaining" => 3,
      "effect" => { "duration_minutes" => 30, "roll_modifier" => 2 } }
  }

  def ctx_with(&block)
    Harness::Turn::Context.new(player_location: yard, game_time: 500, llm_nuance: StubLLM.new(&block))
  end

  def step(intent = "casts a blessing on themselves")
    Harness::Dispatcher::Step.new(runner: "cast", intent: intent, args: {})
  end

  it "binds free text to an owned ability (typo included), resolves, and the effect lands" do
    player.update!(abilities: [ bless_row ])
    ctx = ctx_with { { "ability" => "bless", "target" => nil }.to_json }

    out = described_class.new.run(context: ctx, scene: { "present_characters" => [] }, input: "cast bles on myself", step: step)

    expect(out.status).to eq(:ok)
    resolve = out.tool_calls.find { |t| t["name"] == "resolve" }
    expect(resolve).to be_present
    expect(resolve.dig("result", "effect_applied", "name")).to eq("Bless")
    expect(Harness::Character::ActiveEffects.roll_modifier(player.reload, now: 500)).to eq(2)
    expect(player.abilities.first["uses_remaining"]).to eq(2)
  end

  it "redispatches when no owned ability plausibly matches" do
    player.update!(abilities: [ bless_row ])
    ctx = ctx_with { { "ability" => nil }.to_json }

    out = described_class.new.run(context: ctx, scene: { "present_characters" => [] }, input: "cast meteor swarm", step: step)
    expect(out.status).to eq(:redispatch)
    expect(Harness::Character::ActiveEffects.active_for(player.reload, now: 500)).to be_empty
  end

  describe "fragment suppression on control casts" do
    let(:charm_row) {
      { "id" => "charm_word", "name" => "Charm Word", "effect_kind" => "control", "stat" => "charisma",
        "description" => "A single sentence delivered with terrible warmth.",
        "opposed_by" => "wisdom", "uses_per_rest" => 2, "uses_remaining" => 2 }
    }
    let!(:mark) { Npc.create!(name: "Bodil", location: yard, wisdom: 8, max_hp: 20, current_hp: 20) }

    it "emits no fragment for a person-targeted control cast" do
      player.update!(abilities: [ charm_row ])
      ctx = ctx_with { { "ability" => "charm_word", "target" => "Bodil" }.to_json }
      out = described_class.new.run(context: ctx,
                                    scene: { "present_characters" => [ { "id" => mark.id, "name" => "Bodil" } ] },
                                    input: "cast charm word on Bodil", step: step("charms Bodil"))
      # A control contest's effect IS the target's compliance — that voice
      # belongs to initiative, so no fragment renders here.
      expect(out.tool_calls.map { |t| t["name"] }).to include("resolve")
      expect(out.tool_calls.map { |t| t["name"] }).not_to include("display_fragment")
    end

    it "renders a self-cast's own fragment (the cast's prose island)" do
      player.update!(abilities: [ bless_row ])
      ctx = ctx_with { |full|
        full.include?("render ONE spellcast") ? "Light settles over you." :
          { "ability" => "bless", "target" => nil }.to_json
      }
      out = described_class.new.run(context: ctx, scene: { "present_characters" => [] }, input: "cast bless", step: step)
      frag = out.tool_calls.find { |t| t["name"] == "display_fragment" }
      expect(frag&.dig("args", "text")).to eq("Light settles over you.")
    end
  end

  describe "stage-2 atom blocks" do
    # Content-sniffing stub: the cast runner makes a bind emit, then (for
    # compose/volatile spells) a composer call — tell them apart by prompt.
    def two_stage_stub(ability_id, composed, calls)
      StubLLM.new do |full|
        if full.include?("casting intent")
          calls << :bind
          { "ability" => ability_id, "target" => nil }.to_json
        elsif full.include?("render ONE spellcast")
          calls << :fragment
          "The magic settles."
        else
          calls << :compose
          composed.to_json
        end
      end
    end

    def composed_coins(delta)
      { "narrative" => "coin condenses out of the air",
        "atoms" => [ { "kind" => "coins", "who" => "caster", "delta" => delta } ] }
    end

    it "commits an authored atoms block on a successful cast and logs the composite event" do
      player.update!(abilities: [ {
        "id" => "sanctify", "name" => "Sanctify", "effect_kind" => "buff", "stat" => "wisdom",
        "description" => "marks the ground", "uses_per_rest" => 2, "uses_remaining" => 2,
        "atoms" => [
          { "kind" => "alter_location", "alteration" => "the ground is consecrated" },
          { "kind" => "timed_effect", "who" => "caster", "name" => "Sanctified Ground", "duration_minutes" => 60, "roll_modifier" => 1 }
        ],
        "atoms_narrative" => "the ground takes the blessing"
      } ])
      calls = []
      ctx = ctx_with(&two_stage_stub("sanctify", nil, calls).method(:call))

      out = described_class.new.run(context: ctx, scene: { "present_characters" => [] }, input: "cast sanctify", step: step)

      expect(out.status).to eq(:ok)
      expect(calls).to eq([ :bind, :fragment ])  # authored block never composes
      expect(yard.reload.properties["alterations"]).to include("the ground is consecrated")
      expect(Harness::Character::ActiveEffects.roll_modifier(player.reload, now: 500)).to eq(1)
      expect(Event.order(:id).last.details.dig("narrative", "details")).to eq("the ground takes the blessing")
      expect(out.tool_calls.map { |t| t["name"] }).to include("spell_alter_location", "spell_timed_effect")
    end

    it "compose-class binds on first successful cast, caches onto the player's row, and replays without the composer" do
      player.update!(abilities: [ {
        "id" => "boon", "name" => "Boon", "effect_kind" => "buff", "stat" => "wisdom",
        "description" => "a small fortune arrives", "uses_per_rest" => 3, "uses_remaining" => 3,
        "compose" => true
      } ])
      calls = []
      ctx = ctx_with(&two_stage_stub("boon", composed_coins(7), calls).method(:call))

      described_class.new.run(context: ctx, scene: { "present_characters" => [] }, input: "cast boon", step: step)
      expect(calls).to eq([ :bind, :compose, :fragment ])
      cached = player.reload.abilities.first
      expect(cached["atoms"].first["delta"]).to eq(7)
      expect(cached["atoms_narrative"]).to match(/coin condenses/)
      expect(cached["uses_remaining"]).to eq(2)  # the cache writeback must not resurrect the spent use
      expect(player.coins.to_i).to eq(7)

      described_class.new.run(context: ctx, scene: { "present_characters" => [] }, input: "cast boon", step: step)
      expect(calls).to eq([ :bind, :compose, :fragment, :bind, :fragment ])  # cached — no second composition
      expect(player.reload.coins.to_i).to eq(14)
    end

    it "volatile-class re-composes EVERY cast and never caches" do
      player.update!(abilities: [ {
        "id" => "wish", "name" => "Wish", "effect_kind" => "buff", "stat" => "wisdom",
        "description" => "the world strains to oblige", "uses_per_rest" => 3, "uses_remaining" => 3,
        "volatile" => true
      } ])
      calls = []
      stub = two_stage_stub("wish", composed_coins(3), calls)
      ctx = ctx_with(&stub.method(:call))

      described_class.new.run(context: ctx, scene: { "present_characters" => [] }, input: "I wish for pocket money", step: step)
      described_class.new.run(context: ctx, scene: { "present_characters" => [] }, input: "I wish for pocket money", step: step)

      expect(calls).to eq([ :bind, :compose, :fragment, :bind, :compose, :fragment ])
      expect(player.reload.abilities.first).not_to have_key("atoms")
      # The worded wish reaches the composer (volatile context, not spell prose alone).
      compose_input = stub.user_calls.find { |u| u.include?("pocket money") }
      expect(compose_input).to be_present
    end
  end
end
